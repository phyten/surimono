import AppKit
import OSLog
import SurimonoCore
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
    var onZoomChange: ((Double) -> Void)?
    /// Opens a link outside the app; replaced in tests.
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private static let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "WebPage")
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    var zoom: Double { webView.map { Double($0.pageZoom) } ?? 1 }

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

    /// Loads the file the first time the page is shown, and keeps the page while the setting stays. A changed
    /// JavaScript setting takes a new web view, because a configuration cannot change once the view exists.
    func show(_ fileURL: URL, allowsJavaScript: Bool) {
        if webView != nil, self.allowsJavaScript == allowsJavaScript { return }
        if webView != nil {
            close()
            onRestart?()
        }
        self.allowsJavaScript = allowsJavaScript
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        Self.installPrintBridge(in: configuration.userContentController, handler: PrintMessageHandler(self))
        let webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = false
        container.addSubview(webView)
        self.webView = webView
        self.fileURL = fileURL
        load()
        // A page that replaces one on screen takes the keys at once.
        if container.window != nil { focus() }
    }

    /// The file changed on disk: show it from the start.
    func reload() {
        guard webView != nil else { return }
        load()
    }

    private func load() {
        guard let webView, let fileURL else { return }
        // The document may refer to files next to it, such as images and style sheets.
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    /// Applies a changed JavaScript setting whether or not the page is on screen: a page kept while paper or the tray
    /// is shown must not go on running scripts the reader turned off. A page off screen is loaded again when it shows.
    func applyJavaScriptSetting(_ allowsJavaScript: Bool) {
        guard webView != nil, self.allowsJavaScript != allowsJavaScript, let fileURL else { return }
        close()
        onRestart?()
        if container.window != nil { show(fileURL, allowsJavaScript: allowsJavaScript) }
    }

    /// How long after the reader's own click or key a page may still ask to print, as a print button does at once.
    static let printGestureWindowMilliseconds = 1500

    /// A page's print button opens the print tray. The page's `window.print` only raises an event on the document;
    /// a script in the app's own world hears it and tells the app, so the page itself gets no message handler.
    /// Any page script can raise that event too, so the app's script passes on one request per click or key of the
    /// reader: only trusted events, which a page cannot make, allow the next one. A page printing on a timer then
    /// cannot keep sending the reader back to the tray.
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
                source: """
                    (() => {
                      let gestureAt = null;
                      const note = event => { if (event.isTrusted) gestureAt = performance.now(); };
                      for (const type of ['mousedown', 'mouseup', 'click', 'keydown', 'keyup']) {
                        window.addEventListener(type, note, true);
                      }
                      document.addEventListener('\(printEventName)', () => {
                        if (gestureAt === null || performance.now() - gestureAt > \(printGestureWindowMilliseconds)) {
                          return;
                        }
                        gestureAt = null;
                        window.webkit.messageHandlers.\(printMessageName).postMessage(null);
                      });
                    })();
                    """,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld))
        controller.add(handler, contentWorld: contentWorld, name: printMessageName)
    }

    func close() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        allowsJavaScript = nil
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

    /// The page as it is now, as HTML.
    func snapshot() async -> Snapshot {
        guard let webView, webView.url != nil else { return .notLoaded }
        do {
            // An isolated world works whether or not the page's own JavaScript may run.
            let value = try await webView.callAsyncJavaScript(
                HTMLSnapshotScript.javaScript, arguments: [:], in: nil, contentWorld: Self.contentWorld)
            guard let json = value as? String, let snapshot = HTMLSnapshot(scriptResult: json) else { return .failed }
            return .captured(snapshot)
        } catch {
            Self.logger.error("Capturing the web page failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    func resetZoom() { setZoom(1) }

    private func setZoom(_ value: Double) {
        guard let webView, abs(Double(webView.pageZoom) - value) > 0.001 else { return }
        webView.pageZoom = CGFloat(value)
        onZoomChange?(value)
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
        guard let url = navigationAction.request.url, let fileURL else { return decisionHandler(.cancel) }
        let type = navigationAction.navigationType
        let target: NavigationTarget =
            switch navigationAction.targetFrame?.isMainFrame {
            case true?: .mainFrame
            case false?: .subframe
            case nil: .newWindow(byUser: type == .linkActivated)
            }
        decisionHandler(perform(Self.decision(for: url, type: type, target: target, document: fileURL), for: url))
    }
}

extension WebPageController: WKUIDelegate {
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pages may open windows only in answer to a click (see javaScriptCanOpenWindowsAutomatically), so a window
        // asked for here comes from the reader.
        guard let url = navigationAction.request.url, let fileURL else { return nil }
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

/// Holds the web view and catches the Esc the page did not use, which hides the band as it does on paper.
final class WebPageContainerView: NSView {
    var onEscape: (() -> Bool)?

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
