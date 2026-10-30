import AppKit
import PDFKit
import SurimonoCore
import WebKit

/// Lays out HTML in an off-screen WKWebView and prints it into a paginated PDF.
@MainActor
public final class WebPaginator: NSObject {
    public enum Source: Sendable {
        case html(String, baseURL: URL?)
        case file(URL, readAccessURL: URL)
        /// A copy of a live page, which may read the files under its document's directory and no others.
        case snapshot(String, directory: URL)
    }

    public struct Margins: Sendable, Equatable {
        public var top: CGFloat
        public var left: CGFloat
        public var bottom: CGFloat
        public var right: CGFloat

        public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public static func uniform(millimeters: Double) -> Margins {
            let points = CGFloat(millimeters * 72 / 25.4)
            return Margins(top: points, left: points, bottom: points, right: points)
        }
    }

    public enum PaginationError: Error, Equatable {
        case loadFailed(String)
        case timedOut
        case printFailed
        case emptyDocument
    }

    @MainActor
    public struct Result {
        public let document: PDFDocument
        public let preparationResult: String?
        /// The document's own `@page` rules with a size, read before the preparation script ran; empty unless asked.
        public let pageRules: [PageRule]

        public init(document: PDFDocument, preparationResult: String? = nil, pageRules: [PageRule] = []) {
            self.document = document
            self.preparationResult = preparationResult
            self.pageRules = pageRules
        }
    }

    /// Upper bound for the print step, which normally finishes in well under a second.
    var printTimeout: Duration = .seconds(60)
    /// Sessions whose web view and temporary files have not been released yet (observed by tests).
    private(set) var openSessionCount = 0
    /// Number of print operations started (observed by tests).
    private(set) var printStartCount = 0
    /// Test hooks that make the order of events around printing deterministic.
    var didStartWaitingForResources: (@MainActor () -> Void)?
    var didFinishPrinting: (@MainActor () -> Void)?
    /// Receives whether the document may draw below the paper (observed by tests).
    var didCheckPageRules: (@MainActor (Bool) -> Void)?

    public override init() {}

    public func paginate(
        _ source: Source, pageSize: CGSize, margins: Margins, allowsJavaScript: Bool,
        printsBackgrounds: Bool = true, preparationScript: String? = nil, timeout: Duration = .seconds(15)
    ) async throws -> PDFDocument {
        try await paginateWithResult(
            source, pageSize: pageSize, margins: margins, allowsJavaScript: allowsJavaScript,
            printsBackgrounds: printsBackgrounds, preparationScript: preparationScript, timeout: timeout
        ).document
    }

    /// Returns the preparation script's string result together with the PDF made from that same DOM.
    /// - Parameter readsPageRules: Whether to read the document's `@page` rules into the result.
    public func paginateWithResult(
        _ source: Source, pageSize: CGSize, margins: Margins, allowsJavaScript: Bool,
        printsBackgrounds: Bool = true, preparationScript: String? = nil, readsPageRules: Bool = false,
        timeout: Duration = .seconds(15)
    ) async throws -> Result {
        openSessionCount += 1
        let session = PaginationSession(
            pageSize: pageSize, margins: margins, allowsJavaScript: allowsJavaScript,
            printsBackgrounds: printsBackgrounds, printTimeout: printTimeout,
            onPrintStart: { [weak self] in self?.printStartCount += 1 },
            onPrintFinish: { [weak self] in self?.didFinishPrinting?() },
            onClose: { [weak self] in self?.openSessionCount -= 1 })
        // Closing is deferred to the print completion while the print thread still uses the session.
        defer { session.requestClose() }

        try session.load(source)
        try await Self.waitUntil(timeout: timeout) { session.navigationState != .loading }
        if case .failed(let message) = session.navigationState { throw PaginationError.loadFailed(message) }

        didStartWaitingForResources?()
        try await Self.waitForResources(in: session.webView, timeout: timeout)
        // Before the preparation, whose presets may remove the document's style elements.
        let pageRules =
            readsPageRules
            ? PageRule.rules(
                fromJSON: try await runPreparationScript(PageRule.javaScript, in: session.webView, timeout: timeout)
                    ?? "")
            : []
        let preparationResult: String?
        if let preparationScript, !preparationScript.isEmpty {
            preparationResult = try await runPreparationScript(preparationScript, in: session.webView, timeout: timeout)
        } else {
            preparationResult = nil
        }
        try Task.checkCancellation()
        // Only a document with `@page` rules can set margins of its own and so draw below the paper; an unknown
        // answer counts as yes.
        let mayDrawBelowPaper: Bool
        do {
            mayDrawBelowPaper =
                try await runPreparationScript(Self.pageRuleProbe, in: session.webView, timeout: timeout) != "false"
        } catch PaginationError.timedOut {
            mayDrawBelowPaper = true
        }
        didCheckPageRules?(mayDrawBelowPaper)
        return Result(
            document: try await session.printToPDF(checkingBelowPaper: mayDrawBelowPaper),
            preparationResult: preparationResult, pageRules: pageRules)
    }

    /// Returns "true" when a style sheet of the document, including those a script adopted, has an `@page` rule or
    /// cannot be read, and "false" otherwise.
    static let pageRuleProbe = """
        const hasPageRule = list => Array.from(list || []).some(rule => {
          if (rule.type === CSSRule.PAGE_RULE) return true;
          try { if (rule.styleSheet && hasPageRule(rule.styleSheet.cssRules)) return true; } catch (_) { return true; }
          try { return hasPageRule(rule.cssRules); } catch (_) { return false; }
        });
        const sheets = Array.from(document.styleSheets).concat(Array.from(document.adoptedStyleSheets || []));
        return String(sheets.some(sheet => {
          try { return hasPageRule(sheet.cssRules); } catch (_) { return true; }
        }));
        """

    /// Waits for the page's images and fonts, but prints what has loaded once the timeout passes.
    static func waitForResources(in webView: WKWebView, timeout: Duration) async throws {
        let script = """
            if (document.readyState !== 'complete') {
              await new Promise(resolve => window.addEventListener('load', resolve, { once: true }));
            }
            if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
            await Promise.all(Array.from(document.images).filter(image => !image.complete).map(image =>
              new Promise(resolve => {
                image.addEventListener('load', resolve, { once: true });
                image.addEventListener('error', resolve, { once: true });
              })));
            return true;
            """
        var finished = false
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            finished = true
        }
        do {
            try await Self.waitUntil(timeout: timeout) { finished }
        } catch PaginationError.timedOut {
            // Missing images or fonts should not block printing; cancellation still propagates.
        }
    }

    private func runPreparationScript(_ script: String, in webView: WKWebView, timeout: Duration) async throws
        -> String?
    {
        var finished = false
        var result: String?
        Task { @MainActor in
            // Runs in an isolated world so it still works when the page's own JavaScript is disabled.
            // A failing cleanup script must not block printing, so its error is deliberately ignored.
            let value = try? await webView.callAsyncJavaScript(
                script, arguments: [:], in: nil, contentWorld: .world(name: "surimono"))
            result = value as? String
            finished = true
        }
        // Unlike a failing script, a script that never settles cannot be printed as requested.
        try await Self.waitUntil(timeout: timeout) { finished }
        return result
    }

    static func waitUntil(timeout: Duration, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { throw PaginationError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Returns HTML whose relative URLs resolve against `baseURL`. The first `<base href>` in a document decides
    /// its base URL, so this inserts one at the start of the head. A `<base href>` the document already has is
    /// resolved against `baseURL` first, so it keeps its meaning after the HTML moves to a temporary file.
    static func injectingBase(_ baseURL: URL, into html: String) -> String {
        var base = baseURL
        var isDirectory: ObjCBool = false
        if !base.absoluteString.hasSuffix("/"),
            FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue
        {
            base = URL(fileURLWithPath: base.path, isDirectory: true)
        }
        if let existing = firstBaseHref(in: html), let resolved = URL(string: existing, relativeTo: base) {
            base = resolved.absoluteURL
        }
        let href = base.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let tag = "<base href=\"\(href)\">"
        // Right after the doctype, the element becomes the first child of the head without switching the
        // document into quirks mode. Leading whitespace and comments may precede the doctype.
        var index = html.startIndex
        while true {
            while index < html.endIndex, html[index].isWhitespace || html[index] == "\u{FEFF}" {
                index = html.index(after: index)
            }
            guard html[index...].hasPrefix("<!--"), let end = html.range(of: "-->", range: index..<html.endIndex)
            else { break }
            index = end.upperBound
        }
        if html[index...].prefix(9).lowercased() == "<!doctype", let end = html[index...].firstIndex(of: ">") {
            index = html.index(after: end)
        }
        return String(html[..<index]) + tag + String(html[index...])
    }

    /// The `href` of the first real `<base>` element, ignoring comments and the contents of scripts and styles.
    private static func firstBaseHref(in html: String) -> String? {
        let visible = html.replacingOccurrences(
            of: #"<!--[\s\S]*?-->|<script\b[\s\S]*?</script>|<style\b[\s\S]*?</style>"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        let pattern = #"<base\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: visible, range: NSRange(visible.startIndex..., in: visible))
        else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: visible) {
                return decodingCharacterReferences(String(visible[range]))
            }
        }
        return nil
    }

    /// Decodes the character references that can appear in an attribute value, such as `&amp;` and `&#38;`.
    /// Unknown named references are kept as written.
    static func decodingCharacterReferences(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);"#) else {
            return value
        }
        var result = ""
        var last = value.startIndex
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value), let nameRange = Range(match.range(at: 1), in: value)
            else { continue }
            let name = value[nameRange]
            let replacement: String? =
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    named[String(name)]
                }
            result += value[last..<whole.lowerBound]
            result += replacement ?? String(value[whole])
            last = whole.upperBound
        }
        return result + value[last...]
    }
}

/// Owns the web view, its window, and the temporary files for one pagination, so they outlive the call until the
/// print thread is done with them.
@MainActor
private final class PaginationSession {
    let webView: WKWebView
    private let window: NSWindow
    private let navigationTracker = NavigationTracker()
    private let snapshotHandler = SnapshotSchemeHandler()
    private let pageSize: CGSize
    private let margins: WebPaginator.Margins
    private let allowsJavaScript: Bool
    private let printTimeout: Duration
    private let onPrintStart: () -> Void
    private let onPrintFinish: () -> Void
    private let onClose: () -> Void
    private var temporaryFiles: [URL] = []
    private var printCompletion: PrintCompletion?
    private var isPrinting = false
    private var closeRequested = false
    private var isClosed = false

    var navigationState: NavigationTracker.State { navigationTracker.state }

    init(
        pageSize: CGSize, margins: WebPaginator.Margins, allowsJavaScript: Bool, printsBackgrounds: Bool,
        printTimeout: Duration, onPrintStart: @escaping () -> Void, onPrintFinish: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.allowsJavaScript = allowsJavaScript
        self.printTimeout = printTimeout
        self.onPrintStart = onPrintStart
        self.onPrintFinish = onPrintFinish
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.suppressesIncrementalRendering = true
        configuration.preferences.shouldPrintBackgrounds = printsBackgrounds
        configuration.setURLSchemeHandler(snapshotHandler, forURLScheme: SnapshotSchemeHandler.scheme)
        let printableWidth = max(pageSize.width - margins.left - margins.right, 72)
        let frame = CGRect(x: 0, y: 0, width: printableWidth, height: pageSize.height)
        webView = WKWebView(frame: frame, configuration: configuration)
        // WebKit only produces non-blank print output for a view that lives in a window.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = navigationTracker
    }

    func load(_ source: WebPaginator.Source) throws {
        switch source {
        case .html(let html, let baseURL?) where baseURL.isFileURL && !allowsJavaScript:
            // loadHTMLString does not grant file read access, so images next to the document would not load.
            // Load a temporary copy instead. Reading is allowed broadly so that references such as ../images/
            // keep working, which is acceptable only because the page cannot run JavaScript to read and send
            // local files.
            let url = temporaryURL(extension: "html")
            try Data(WebPaginator.injectingBase(baseURL, into: html).utf8).write(to: url)
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        case .html(let html, let baseURL):
            // With JavaScript enabled, grant no file access beyond what loadHTMLString allows.
            webView.loadHTMLString(html, baseURL: baseURL)
        case .file(let url, let readAccessURL):
            webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        case .snapshot(let html, let directory):
            snapshotHandler.serve(
                WebPaginator.injectingBase(SnapshotSchemeHandler.rootURL, into: html), directory: directory)
            webView.load(URLRequest(url: SnapshotSchemeHandler.pageURL))
        }
    }

    /// - Parameter checkingBelowPaper: Whether the document may draw below the paper, so that the pages are cut back
    ///   to the paper only after finding nothing there.
    func printToPDF(checkingBelowPaper: Bool) async throws -> PDFDocument {
        let outputURL = temporaryURL(extension: "pdf")
        let printInfo = NSPrintInfo()
        printInfo.paperSize = CGSize(width: pageSize.width, height: pageSize.height + Self.pageHeightAllowance)
        printInfo.topMargin = margins.top
        printInfo.leftMargin = margins.left
        // The allowance goes into the bottom margin, so a document laid out with these margins keeps its height.
        printInfo.bottomMargin = margins.bottom + Self.pageHeightAllowance
        printInfo.rightMargin = margins.right
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // A separate print thread keeps the main run loop free for WebKit's callbacks.
        operation.canSpawnSeparateThread = true
        operation.view?.frame = webView.bounds

        // The completion keeps this session alive (and the session keeps the completion) until printing ends.
        let completion = PrintCompletion { [self] in printDidFinish() }
        printCompletion = completion
        isPrinting = true
        onPrintStart()
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)

        let deadline = ContinuousClock.now + printTimeout
        while completion.result == nil {
            // Cancellation takes precedence over the deadline.
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw WebPaginator.PaginationError.timedOut }
            // Task.sleep returns immediately once cancelled, which would spin the main thread and starve the
            // completion callback, so pause on the main queue instead.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { continuation.resume() }
            }
        }
        // The task may have been cancelled while the last pause was in flight.
        try Task.checkCancellation()
        guard completion.result == true else { throw WebPaginator.PaginationError.printFailed }
        guard let data = try? Data(contentsOf: outputURL), let document = PDFDocument(data: data),
            document.pageCount > 0
        else { throw WebPaginator.PaginationError.emptyDocument }
        return cutToPaper(document, checkingBelowPaper: checkingBelowPaper)
    }

    /// WebKit cuts the printable height into pages of whole CSS pixels and lets a document's `@page` size and margins
    /// override the print info, so a sheet exactly as tall as its page (A4 is 1122.52 pixels) spilled a sliver onto a
    /// page of its own. Pages are laid out this much taller and then cut back to the paper, keeping their top. In the
    /// measured setup 0.5 pt was rounded back to the standard paper size and 1 pt was enough.
    static let pageHeightAllowance: CGFloat = 2

    /// Cuts the pages back to the paper unless something is drawn in the strip the cut would take off. With the
    /// allowance added to the bottom margin, only a document whose own `@page` margin leaves less than that at the
    /// bottom draws there; its pages keep the strip, and composing fits them onto the paper.
    ///
    /// The cut pages come back as a document read anew: PDFKit keeps reporting some characters of a page whose boxes
    /// were just changed at zero size, which would break finding and selecting text on the paper.
    private func cutToPaper(_ document: PDFDocument, checkingBelowPaper: Bool) -> PDFDocument {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        if checkingBelowPaper, pages.contains(where: { Self.drawsBelowPaper($0, paperHeight: pageSize.height) }) {
            return document
        }
        for page in pages {
            let media = page.bounds(for: .mediaBox)
            let height = min(pageSize.height, media.height)
            let paper = CGRect(x: media.minX, y: media.maxY - height, width: media.width, height: height)
            page.setBounds(paper, for: .mediaBox)
            page.setBounds(paper, for: .cropBox)
        }
        return document.dataRepresentation().flatMap(PDFDocument.init(data:)) ?? document
    }

    /// Whether the page draws anything below the paper's height. The strip is rendered on white and any pixel that is
    /// not near-white counts, so text, rules, images and backgrounds all keep the page whole.
    static func drawsBelowPaper(_ page: PDFPage, paperHeight: CGFloat) -> Bool {
        let media = page.bounds(for: .mediaBox)
        let stripHeight = media.height - paperHeight
        guard stripHeight > 0 else { return false }
        let scale: CGFloat = 4
        let width = max(1, Int((media.width * scale).rounded(.up)))
        let height = max(1, Int((stripHeight * scale).rounded(.up)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let data = context.data
        else { return true }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The box's lower left corner lands on the bitmap's origin, so the bitmap holds the bottom of the page.
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: width * height * 4, by: 4)
        where pixels[index] < 250 || pixels[index + 1] < 250 || pixels[index + 2] < 250 {
            return true
        }
        return false
    }

    /// Closes now, or as soon as an in-flight print operation finishes.
    func requestClose() {
        if isPrinting {
            closeRequested = true
        } else {
            close()
        }
    }

    private func printDidFinish() {
        isPrinting = false
        printCompletion = nil
        onPrintFinish()
        if closeRequested { close() }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles.removeAll()
        onClose()
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "surimono-pagination-\(UUID().uuidString).\(pathExtension)")
        temporaryFiles.append(url)
        return url
    }
}

@MainActor
final class NavigationTracker: NSObject, WKNavigationDelegate {
    enum State: Equatable {
        case loading
        case finished
        case failed(String)
    }

    private(set) var state = State.loading

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .finished
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        state = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        state = .failed(error.localizedDescription)
    }
}

private final class PrintCompletion: NSObject, @unchecked Sendable {
    // Written on the main queue from the print callback and read on the main actor.
    nonisolated(unsafe) private(set) var result: Bool?
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    @objc nonisolated func printOperationDidRun(
        _ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.result = success
                self.onFinish()
            }
        }
    }
}
