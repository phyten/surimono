import AppKit
import OSLog
import SurimonoCore
import SurimonoRendering
import SwiftUI
import WebKit

/// The live web page of an HTML document: one WKWebView per window, kept while the window shows paper or the print
/// tray, so that what the reader opened, chose or typed is still there on the way back.
@MainActor
final class WebPageController: NSObject {
    /// The page's superview and next responder; it receives the keys the page leaves unhandled.
    let container = WebPageContainerView()
    private(set) var webView: WKWebView?
    private var fileURL: URL?
    var allowedResourceFolders: [URL] = []
    var isSandboxed: () -> Bool = { SandboxEnvironment.isSandboxed }
    var onFolderAccessRequired: ((URL) -> Void)?
    var onZoomChange: ((Double) -> Void)?
    /// Opens a link outside the app; replaced in tests.
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private static let logger = Logger(subsystem: "app.surimono.Surimono", category: "WebPage")
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The reader's zoom, relative to fitting one slide into the window for a slide deck, and to 100 % otherwise.
    private(set) var zoom: Double = 1
    /// The slide size the page zooms to fit into the window; nil leaves the page at the reader's zoom.
    var fitSize: CGSize? {
        didSet { if fitSize != oldValue { applyZoom() } }
    }
    /// The slide deck the page looks like, as last measured; nil for an ordinary page or before it has loaded.
    private(set) var slideDeck: SlideDeck?
    var onSlideDeckChange: ((SlideDeck?) -> Void)?

    override init() {
        super.init()
        container.onResize = { [weak self] in self?.applyZoom() }
    }

    /// Whether the page was loaded with its JavaScript allowed.
    private(set) var allowsJavaScript: Bool?
    /// Called when the page starts over, so that a copy of its earlier state is no longer used.
    var onRestart: (() -> Void)?
    /// Called when the page calls `window.print()`, instead of the system print dialog.
    var onPrintRequest: (() -> Void)?

    /// The world of the app's own scripts on the page, apart from the page's scripts.
    static let contentWorld = WKContentWorld.world(name: "surimono")
    static let printMessageName = "surimonoPrint"
    static let printEventName = "surimono-print-request"
    static let slidesMessageName = "surimonoSlides"

    /// Loads the file the first time the page is shown, and keeps the page while the setting stays. A changed
    /// JavaScript setting takes a new web view, because a configuration cannot change once the view exists.
    /// A page whose process ended is not loaded by being shown: it waits for the reader (`PageState.ended`).
    func show(_ fileURL: URL, allowsJavaScript: Bool) {
        if state == .ended || state == .reloading { return settingDidChangeWhileEnded(allowsJavaScript) }
        wantsJavaScript = allowsJavaScript
        if webView != nil, self.allowsJavaScript == allowsJavaScript { return }
        if webView != nil {
            close()
            onRestart?()
        }
        // One controller shows one document: the file is taken only when a page is made for it.
        self.fileURL = fileURL
        makeWebView(fileURL, allowsJavaScript: allowsJavaScript)
        load(as: .loading)
        // A page that replaces one on screen takes the keys at once.
        if container.window != nil { focus() }
    }

    private func makeWebView(_ fileURL: URL, allowsJavaScript: Bool) {
        self.allowsJavaScript = allowsJavaScript
        let configuration = WKWebViewConfiguration()
        if isSandboxed() {
            let handler = LocalResourceSchemeHandler(
                access: LocalResourceAccess(documentURL: fileURL, folders: allowedResourceFolders))
            handler.onDenied = { [weak self] folder in self?.onFolderAccessRequired?(folder) }
            configuration.setURLSchemeHandler(handler, forURLScheme: LocalResourceSchemeHandler.scheme)
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        Self.installPrintBridge(in: configuration.userContentController, handler: PrintMessageHandler(self))
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: SlideDeckScript.observerJavaScript(messageName: Self.slidesMessageName),
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.contentWorld))
        configuration.userContentController.add(
            SlideMessageHandler(self), contentWorld: Self.contentWorld, name: Self.slidesMessageName)
        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        container.addSubview(webView)
        self.webView = webView
        applyZoom()
    }

    /// The file changed on disk: show it from the start. For a page whose process ended this is the reader's word to
    /// load it again, and a load already under way for that is replaced by one of the new file.
    func reload() {
        switch state {
        case .notShown: return
        case .ended, .reloading: startRecovery()
        case .live, .loading:
            guard let fileURL, let allowsJavaScript else { return }
            // A provisional start still in transit from the old page must arrive on a different view.
            close()
            onRestart?()
            show(fileURL, allowsJavaScript: allowsJavaScript)
        }
    }

    /// The reader asked for the page again (the failure notice's Try Again): a page whose process ended is loaded
    /// once more. Check the deadline here too: its timer may still be waiting to run on the main actor.
    func reloadEndedPage() {
        expireLoadIfNeeded()
        guard state == .ended else { return }
        startRecovery()
    }

    /// Loads the document again after its process ended, with the JavaScript setting as it is now. Copies waiting
    /// for an earlier load are told that their page was replaced.
    private func startRecovery() {
        guard let fileURL, let allows = wantsJavaScript ?? allowsJavaScript else { return }
        discardEndedWebView()
        makeWebView(fileURL, allowsJavaScript: allows)
        load(as: .reloading)
        if state == .reloading, container.window != nil { focus() }
    }

    /// An app-requested load that does not start reports nothing later. End it immediately so that a copy
    /// cannot take the previous page while waiting for a navigation that does not exist.
    private func load(as started: PageState) {
        guard let webView, let fileURL else { return }
        beginLoad(startNavigation(webView, fileURL, isSandboxed()), as: started, ifUnidentified: .navigationNotStarted)
    }

    private func beginLoad(_ navigation: AnyObject?, as started: PageState, ifUnidentified failure: CaptureFailure) {
        pageGeneration += 1
        loadCount += 1
        clearLoadDeadlines()
        guard let navigation else { return end(failure) }
        self.navigation = navigation
        knownNavigations.add(navigation)
        state = started
        if started == .reloading {
            unattendedDeadline = loadNow() + snapshotTimeout
            scheduleRecoveryTimer()
        }
    }

    /// Starts loading the document and returns what WebKit will report its end with; replaced in tests by one that
    /// holds the navigation or starts none. (A test cannot make a `WKNavigation`: one WebKit did not make stops the
    /// process when it is released, so the navigation is known here only by its identity.)
    var startNavigation: (WKWebView, URL, _ sandboxed: Bool) -> AnyObject? = { webView, fileURL, sandboxed in
        // The document may refer to files next to it, such as images and style sheets.
        if sandboxed {
            webView.load(URLRequest(url: LocalResourceSchemeHandler.url(for: fileURL)))
        } else {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }

    /// A timed-out navigation must stop fetching even if its web view stays in the window.
    var stopNavigation: (WKWebView) -> Void = { $0.stopLoading() }

    /// Applies a changed JavaScript setting whether or not the page is on screen: a page kept while paper or the tray
    /// is shown must not go on running scripts the reader turned off. A page off screen is loaded again when it shows.
    func applyJavaScriptSetting(_ allowsJavaScript: Bool) {
        if state == .ended || state == .reloading { return settingDidChangeWhileEnded(allowsJavaScript) }
        wantsJavaScript = allowsJavaScript
        guard webView != nil, self.allowsJavaScript != allowsJavaScript, let fileURL else { return }
        close()
        onRestart?()
        if container.window != nil { show(fileURL, allowsJavaScript: allowsJavaScript) }
    }

    /// A page whose process ended keeps waiting for the reader when the setting changes: its web view, which cannot
    /// take the new setting, is given up (ending a load under way), and the next load makes one with the setting.
    private func settingDidChangeWhileEnded(_ allowsJavaScript: Bool) {
        wantsJavaScript = allowsJavaScript
        guard webView != nil, self.allowsJavaScript != allowsJavaScript else { return }
        let wasReloading = state == .reloading
        discardEndedWebView()
        if wasReloading { end(.replaced) }
    }

    /// Gives up the web view of a page that stays the same document. The slides it measured go with it, and the
    /// owner is told: the page loaded next may be no deck, and would then report nothing to replace them. This is
    /// not a restart (`onRestart`), which would drop the copies and requests waiting for the page.
    private func discardEndedWebView() {
        let hadSlides = slideDeck != nil
        discardWebView()
        if hadSlides { onSlideDeckChange?(nil) }
    }

    /// How long after the reader's own click or key a page may still ask to print, as a print button does at once.
    static let printGestureWindowMilliseconds = 1500

    /// A page's print button opens the print tray. The page's `window.print` only raises an event on the document;
    /// a script in the app's own world hears it and tells the app, so the page itself gets no message handler.
    /// Any page script can raise that event too, so the app's script passes on one request per click or key of the
    /// reader: only trusted events, which a page cannot make, allow the next one. A page printing on a timer then
    /// cannot keep sending the reader back to the tray. A press and its release are one click or key: the press allows
    /// a request, and the release only keeps that allowance fresh while it is unused (a button prints on the release
    /// of a long press), so a timer that used the press gets nothing more from the release. Pointer events count as
    /// presses too, because a page may cancel the mouse events made from them and still get its click.
    private static func installPrintBridge(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.addUserScript(
            WKUserScript(
                source: """
                    (() => {
                      const request = () => { document.dispatchEvent(new Event('\(printEventName)')); };
                      Object.defineProperty(window, 'print', {
                        value: function print() { request(); }, writable: true, configurable: true,
                      });
                    })();
                    """,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(
            WKUserScript(
                source: printGateScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld))
        controller.add(handler, contentWorld: contentWorld, name: printMessageName)
    }

    /// The script of the app's own world that passes a page's print request on, once per press of the reader.
    static let printGateScript = """
        (() => {
          let gestureAt = null;
          let spent = true;
          let pressedAt = -Infinity;
          const press = event => {
            if (!event.isTrusted || event.repeat) return;
            const now = performance.now();
            // The mouse press made from a pointer press follows it at once; the two are one press.
            if (event.type === 'mousedown' && now - pressedAt < 100) return;
            pressedAt = now;
            gestureAt = now;
            spent = false;
          };
          const release = event => { if (event.isTrusted && !spent) gestureAt = performance.now(); };
          // A click with no press behind it (one an assistive tool makes, or the end of a very long hold)
          // is a press of its own; otherwise it ends the press before it.
          const click = event => {
            const fresh = performance.now() - pressedAt <= \(printGestureWindowMilliseconds);
            if (fresh) release(event); else press(event);
          };
          for (const type of ['pointerdown', 'mousedown', 'keydown']) {
            window.addEventListener(type, press, true);
          }
          for (const type of ['pointerup', 'mouseup', 'keyup']) {
            window.addEventListener(type, release, true);
          }
          window.addEventListener('click', click, true);
          document.addEventListener('\(printEventName)', () => {
            if (spent || performance.now() - gestureAt > \(printGestureWindowMilliseconds)) return;
            spent = true;
            window.webkit.messageHandlers.\(printMessageName).postMessage(null);
          });
        })();
        """

    func close() {
        discardWebView()
        state = .notShown
        wantsJavaScript = nil
    }

    private func discardWebView() {
        clearLoadDeadlines()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        // A copy still waiting for this page's answer gets none.
        pageGeneration += 1
        navigation = nil
        knownNavigations.removeAllObjects()
        allowsJavaScript = nil
        // The page that measured it is gone; the owner learns of a restart separately.
        slideDeck = nil
    }

    /// The slide script measured the page again.
    func slideFactsDidArrive(_ json: String) {
        let deck = SlideDeck.detect(fromJSON: json)
        guard deck != slideDeck else { return }
        slideDeck = deck
        onSlideDeckChange?(deck)
    }

    func focus() {
        guard let webView, let window = webView.window, window.firstResponder !== webView else { return }
        window.makeFirstResponder(webView)
    }

    enum Snapshot: Equatable {
        /// No page has been shown, so there is no state beyond the file.
        case notLoaded
        case captured(HTMLSnapshot)
        case failed
    }

    /// What a copy of the page can expect from it.
    enum PageState: Equatable {
        /// No page has been shown; the file itself is the document's state.
        case notShown
        /// An ordinary load may still show the previous DOM until its navigation finishes.
        case loading
        case live
        /// A process ended or a load failed. The view may be blank, stale or gone; only the reader can retry.
        case ended
        /// Loading again after its process ended; a copy waits for this load to finish.
        case reloading
    }

    /// Why a copy got nothing from the page.
    private enum CaptureFailure: Error {
        case processEnded
        case navigationFailed(domain: String, code: Int)
        case navigationNotStarted
        case navigationTimedOut
        /// The page the copy was asked of has been replaced or closed.
        case replaced
    }

    private(set) var state = PageState.notShown
    private var endReason = CaptureFailure.processEnded
    /// A repeated provisional start for an earlier navigation on this view must not supersede the current one.
    private let knownNavigations = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])
    /// The navigation of this generation.
    private var navigation: AnyObject?
    /// Counts the pages a waiting copy can no longer hear from: ended processes, closed web views, replaced loads.
    private var pageGeneration = 0
    /// The JavaScript setting last asked for; an ended page may have no web view to carry it.
    private var wantsJavaScript: Bool?
    /// Number of times the document was loaded into a web view (observed by tests).
    private(set) var loadCount = 0
    private var isLoadingPage: Bool { state == .loading || state == .reloading }
    private var waiterDeadlines: [UUID: ContinuousClock.Instant] = [:]
    var reloadWaiterCount: Int { waiterDeadlines.count }
    /// With no copies waiting, recovery still has its original budget, measured from the start of the load.
    private var unattendedDeadline: ContinuousClock.Instant?
    private var loadDeadline: ContinuousClock.Instant? { waiterDeadlines.values.max() ?? unattendedDeadline }
    /// Load time can be advanced independently of WebKit's script reply in tests.
    var loadNow: () -> ContinuousClock.Instant = { .now }
    /// Returns the cancellation for this alarm so registering a new deadline can withdraw it.
    var scheduleLoadAlarm: (ContinuousClock.Instant, @escaping @MainActor () -> Void) -> () -> Void = {
        deadline, fire in
        let timer = Task { @MainActor in
            try await Task.sleep(until: deadline, clock: .continuous)
            try Task.checkCancellation()
            fire()
        }
        return { timer.cancel() }
    }
    private var cancelLoadAlarm: (() -> Void)?

    private func clearLoadDeadlines() {
        cancelLoadAlarm?()
        cancelLoadAlarm = nil
        unattendedDeadline = nil
        waiterDeadlines.removeAll()
    }

    private func scheduleRecoveryTimer() {
        guard state == .reloading, let navigation, let deadline = loadDeadline else { return }
        cancelLoadAlarm?()
        let generation = pageGeneration
        cancelLoadAlarm = scheduleLoadAlarm(deadline) { [weak self] in
            guard let self, pageGeneration == generation, self.navigation === navigation else { return }
            expireLoadIfNeeded()
        }
    }

    private func expireLoadIfNeeded() {
        guard isLoadingPage, let deadline = loadDeadline, loadNow() >= deadline else { return }
        end(.navigationTimedOut)
        if let webView { stopNavigation(webView) }
    }

    private func end(_ reason: CaptureFailure) {
        navigation = nil
        clearLoadDeadlines()
        endReason = reason
        state = .ended
    }

    /// How long one copy of the page may take, a reload after an ended process included. The script clones the DOM,
    /// turns each canvas into a PNG data URL and serializes the whole document, so its time grows with the page.
    /// Measured once on a development Mac (Apple silicon, 2026-11): 300,000 paragraphs with sixteen 1600×1200
    /// canvases, a copy of 35 MB, took 0.9 s; slower machines and larger pages were not measured. The minute is the
    /// base the paginator allows its print step. A page that takes longer, or never answers, ends in the failure
    /// notice instead of staying in "loading".
    var snapshotTimeout: Duration = .seconds(60)

    /// Asks the page to run the copy script; replaced in tests by one that holds its reply.
    var startSnapshot: (WKWebView, @escaping WebPaginator.Reply) -> Void = { webView, reply in
        // An isolated world works whether or not the page's own JavaScript may run.
        webView.callAsyncJavaScript(
            HTMLSnapshotScript.javaScript, arguments: [:], in: nil, in: WebPageController.contentWorld,
            completionHandler: reply)
    }

    /// The page as it is now, as HTML. WebKit may never call back (its process stopped, or a page that never
    /// settles), so the wait has a deadline and ends with the process.
    func snapshot() async -> Snapshot {
        guard state != .notShown else { return .notLoaded }
        let generation = pageGeneration
        let deadline = loadNow() + snapshotTimeout
        do {
            if isLoadingPage { try await waitForReload(generation: generation, until: deadline) }
            try checkPage(generation: generation)
            guard state == .live, let webView, webView.url != nil else { throw CaptureFailure.replaced }
            // WebKit waits on the system clock. Only the budget left after navigation belongs to the script.
            let scriptDeadline = ContinuousClock.now + loadNow().duration(to: deadline)
            let value = try await WebPaginator.reply(
                until: scriptDeadline,
                ended: { [weak self] in
                    guard let self else { return "" }
                    guard pageGeneration != generation else { return nil }
                    if state == .ended, case .replaced = endReason { return "" }
                    return state == .ended ? Self.endedMessage : ""
                },
                start: { [startSnapshot] reply in startSnapshot(webView, reply) })
            try checkPage(generation: generation)
            guard let json = value as? String, let snapshot = HTMLSnapshot(scriptResult: json) else { return .failed }
            return .captured(snapshot)
        } catch {
            Self.logCaptureFailure(error)
            return .failed
        }
    }

    private func checkPage(generation: Int) throws {
        if state == .ended { throw endReason }
        guard pageGeneration == generation else { throw CaptureFailure.replaced }
    }

    /// A copy keeps the same deadline through navigation and script execution. Only waiters for this generation
    /// may change its deadline; a cancelled or replaced copy cannot keep a later load waiting.
    private func waitForReload(generation: Int, until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        expireLoadIfNeeded()
        try checkPage(generation: generation)
        guard isLoadingPage else { return }
        let id = UUID()
        waiterDeadlines[id] = deadline
        scheduleRecoveryTimer()
        defer {
            if waiterDeadlines.removeValue(forKey: id) != nil {
                expireLoadIfNeeded()
                scheduleRecoveryTimer()
            }
        }
        while isLoadingPage, pageGeneration == generation {
            try Task.checkCancellation()
            let remaining = loadNow().duration(to: deadline)
            guard remaining > .zero else {
                expireLoadIfNeeded()
                throw CaptureFailure.navigationTimedOut
            }
            try await Task.sleep(for: min(remaining, Duration.milliseconds(20)), clock: .continuous)
        }
    }

    private static let endedMessage = "ended"

    /// Only a fixed category and the error's domain and code are logged: a JavaScript exception's description and
    /// `userInfo` can carry text of the document and the place of the file.
    private static func logCaptureFailure(_ error: any Error) {
        var domain = (error as NSError).domain
        var code = (error as NSError).code
        let category: String
        switch error {
        case WebPaginator.PaginationError.timedOut, CaptureFailure.navigationTimedOut: category = "deadline"
        case WebPaginator.PaginationError.loadFailed(endedMessage), CaptureFailure.processEnded:
            category = "process ended"
        case WebPaginator.PaginationError.loadFailed, CaptureFailure.replaced: category = "page replaced"
        case CaptureFailure.navigationFailed(let failedDomain, let failedCode):
            category = "navigation failed"
            domain = failedDomain
            code = failedCode
        case CaptureFailure.navigationNotStarted: category = "navigation not started"
        case is CancellationError: category = "cancelled"
        default: category = "script error"
        }
        logger.error(
            "Capturing the web page failed: \(category, privacy: .public) (\(domain, privacy: .public) \(code))")
    }

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    func resetZoom() { setZoom(1) }

    private func setZoom(_ value: Double) {
        guard abs(zoom - value) > 0.001 else { return }
        zoom = value
        applyZoom()
        onZoomChange?(value)
    }

    /// The scale that fits one slide into the page's area, which follows the window.
    var fitScale: Double {
        let bounds = container.bounds.size
        guard let fitSize, fitSize.width > 0, fitSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return 1
        }
        return min(bounds.width / fitSize.width, bounds.height / fitSize.height)
    }

    /// Page zoom rather than magnification: the page lays itself out for a viewport of the slide's size, so the
    /// deck's own script and layout go on working as in a browser zoomed to fit.
    private func applyZoom() {
        guard let webView else { return }
        let value = CGFloat(fitScale * zoom)
        if abs(webView.pageZoom - value) > 0.0001 { webView.pageZoom = value }
    }

    enum NavigationDecision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    enum NavigationTarget: Equatable {
        case mainFrame
        /// A frame inside the document, such as an iframe.
        case subframe
        /// A new window; `byUser` when the reader clicked a link or the page opened it in answer to a click.
        case newWindow(byUser: Bool)
    }

    /// What happens to a navigation. The document itself loads, reloads and jumps within itself, and its frames load
    /// what the document puts in them. A link the reader follows to the web or to mail opens outside. Anything else,
    /// such as a form sent anywhere, a script moving the page, or a link to another local file, is dropped, so that
    /// the window keeps showing its document and sends nothing.
    static func decision(
        for url: URL, type: WKNavigationType, target: NavigationTarget, document: URL
    ) -> NavigationDecision {
        let external: NavigationDecision = opensExternally(url) ? .openExternally : .cancel
        switch target {
        case .newWindow(let byUser):
            return byUser ? external : .cancel
        case .subframe:
            switch type {
            case .formSubmitted, .formResubmitted: return .cancel
            case .linkActivated: return external
            default: return .allow
            }
        case .mainFrame:
            if type != .formSubmitted, type != .formResubmitted, isSameDocument(url, as: document) { return .allow }
            return type == .linkActivated ? external : .cancel
        }
    }

    private func perform(_ decision: NavigationDecision, for url: URL) -> WKNavigationActionPolicy {
        if decision == .openExternally { openExternally(url) }
        return decision == .allow ? .allow : .cancel
    }

    /// Links the browser would follow open there instead; the window keeps showing the document.
    static func opensExternally(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The document itself, at any fragment: loading it, reloading it and jumping within it stay in the window.
    static func isSameDocument(_ url: URL, as document: URL) -> Bool {
        func withoutFragment(_ url: URL) -> URL? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url?.standardizedFileURL
        }
        return url.isFileURL && withoutFragment(url) == withoutFragment(document)
    }
}

extension WebPageController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let requested = navigationAction.request.url, let fileURL else { return decisionHandler(.cancel) }
        let url = isSandboxed() ? (LocalResourceSchemeHandler.fileURL(for: requested) ?? requested) : requested
        let type = navigationAction.navigationType
        let target: NavigationTarget =
            switch navigationAction.targetFrame?.isMainFrame {
            case true?: .mainFrame
            case false?: .subframe
            case nil: .newWindow(byUser: type == .linkActivated)
            }
        decisionHandler(perform(Self.decision(for: url, type: type, target: target, document: fileURL), for: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationDidStart(webView, navigation)
    }

    func navigationDidStart(_ webView: WKWebView, _ navigation: AnyObject?) {
        guard webView === self.webView, state != .ended, state != .notShown else { return }
        if let navigation, knownNavigations.contains(navigation) { return }
        // A nil start replaces the old DOM, but no later finish can prove it belongs to this start.
        beginLoad(navigation, as: state == .reloading ? .reloading : .loading, ifUnidentified: .replaced)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationDidFinish(webView, navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationDidFail(webView, navigation, error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        navigationDidFail(webView, navigation, error)
    }

    /// Only the load the page is waiting for makes it live. A late finish must respect the deadline even if the
    /// timer or the waiting copy has not run yet.
    func navigationDidFinish(_ webView: WKWebView, _ navigation: AnyObject?) {
        guard webView === self.webView, isLoadingPage, navigation === self.navigation else { return }
        expireLoadIfNeeded()
        guard isLoadingPage else { return }
        clearLoadDeadlines()
        state = .live
    }

    /// The page did not come: a copy must not take what the web view showed before for it. The reader's next
    /// request loads it once more.
    func navigationDidFail(_ webView: WKWebView, _ navigation: AnyObject?, _ error: any Error) {
        guard webView === self.webView, isLoadingPage, navigation === self.navigation else { return }
        pageGeneration += 1
        end(.navigationFailed(domain: (error as NSError).domain, code: (error as NSError).code))
    }

    /// The page is blank from here on and answers nothing it was asked. A copy in flight fails with the notice the
    /// reader can retry from, and so does every later one until the reader has the page loaded again. The page is
    /// not loaded again here: that would run the document's scripts and fetch its resources once more behind the
    /// reader's back, possibly without end, and what the reader had typed or opened is gone either way.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        Self.logger.error("The web content process of the page ended")
        pageGeneration += 1
        end(.processEnded)
    }
}

extension WebPageController: WKUIDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pages may open windows only in answer to a click (see javaScriptCanOpenWindowsAutomatically), so a window
        // asked for here comes from the reader.
        guard let requested = navigationAction.request.url, let fileURL else { return nil }
        let url = isSandboxed() ? (LocalResourceSchemeHandler.fileURL(for: requested) ?? requested) : requested
        let type = navigationAction.navigationType
        let byUser = type == .linkActivated || type == .other
        _ = perform(
            Self.decision(for: url, type: type, target: .newWindow(byUser: byUser), document: fileURL), for: url)
        return nil
    }
}

/// Passes the page's print requests on without the user content controller keeping the controller alive.
private final class PrintMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var controller: WebPageController?

    init(_ controller: WebPageController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === controller?.webView else { return }
        controller?.onPrintRequest?()
    }
}

/// Passes the slide script's measurements on, as `PrintMessageHandler` does for print requests.
private final class SlideMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var controller: WebPageController?

    init(_ controller: WebPageController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === controller?.webView,
            let json = message.body as? String
        else { return }
        controller?.slideFactsDidArrive(json)
    }
}

/// Holds the web view and catches the Esc the page did not use, which hides the band as it does on paper.
final class WebPageContainerView: NSView {
    var onEscape: (() -> Bool)?
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
            onEscape?() == true
        {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The page takes the keys as soon as it is shown; wait until SwiftUI has finished placing the view.
        Task { @MainActor [weak self] in
            guard let self, let window, let webView = subviews.first, window.firstResponder !== webView else { return }
            window.makeFirstResponder(webView)
        }
    }
}

struct WebPageView: NSViewRepresentable {
    let controller: WebPageController
    let fileURL: URL
    let allowsJavaScript: Bool
    /// Returns true when the band was hidden.
    var onEscape: () -> Bool

    func makeNSView(context: Context) -> WebPageContainerView {
        controller.show(fileURL, allowsJavaScript: allowsJavaScript)
        controller.container.onEscape = onEscape
        return controller.container
    }

    func updateNSView(_ view: WebPageContainerView, context: Context) {
        view.onEscape = onEscape
        controller.show(fileURL, allowsJavaScript: allowsJavaScript)
    }

    static func dismantleNSView(_ view: WebPageContainerView, coordinator: ()) {
        // The page lives on in its controller while paper or the print tray is shown.
        view.onEscape = nil
    }
}
