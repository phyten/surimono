import AppKit
import PDFKit
import SurimonoCore
import WebKit

/// Draws one document's first page in any print theme, fast enough for a style picker.
///
/// The document is laid out once in an off-screen web view as wide as the printable area of its page, as the
/// paginator lays it out. Each theme then only replaces the page's style sheet and decorations before the first
/// page's area is captured as a one-page vector PDF. The page is drawn for the screen rather than printed, so it can
/// differ a little from the printed first page; it is a sample for choosing a look, never output.
@MainActor
public final class ThemeSampler {
    public enum SamplingError: Error, Equatable {
        case loadFailed(String)
        case closed
        case emptyPage
    }

    /// The logical page the samples stand for.
    public let pageSize: CGSize
    public let margins: WebPaginator.Margins
    /// The area each sample covers, inside the page's margins.
    public var printableSize: CGSize {
        CGSize(
            width: max(pageSize.width - margins.left - margins.right, 72),
            height: max(pageSize.height - margins.top - margins.bottom, 72))
    }
    /// Number of themes drawn rather than served from the cache (observed by tests).
    public private(set) var drawCount = 0

    private let html: String
    private let baseURL: URL?
    private let textScale: Double
    private let timeout: Duration
    private var session: Session?
    private var appliedTheme: PrintTheme?
    private var samples: [String: (theme: PrintTheme, page: PDFPage)] = [:]
    private var isBusy = false
    private var isClosed = false

    /// - Parameter html: A whole document as `HTMLDocumentBuilder` builds it, with exactly one style element.
    public init(
        html: String, baseURL: URL?, pageSize: CGSize, margins: WebPaginator.Margins, textScale: Double = 1,
        timeout: Duration = .seconds(15)
    ) {
        self.html = html
        self.baseURL = baseURL
        self.pageSize = pageSize
        self.margins = margins
        self.textScale = textScale
        self.timeout = timeout
    }

    /// The sample of `theme`, drawn once and then kept until the sampler closes. Requests are served one at a time.
    public func firstPage(for theme: PrintTheme) async throws -> PDFPage {
        if let sample = samples[theme.id], sample.theme == theme { return sample.page }
        // The web view shows one theme at a time, so a request waits for the one before it.
        while isBusy { try await Task.sleep(for: .milliseconds(5)) }
        if let sample = samples[theme.id], sample.theme == theme { return sample.page }
        guard !isClosed else { throw SamplingError.closed }
        isBusy = true
        defer { isBusy = false }
        let session = try await openSession()
        try Task.checkCancellation()
        try await apply(theme, in: session.webView)
        try Task.checkCancellation()
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: printableSize)
        let data = try await session.webView.pdf(configuration: configuration)
        guard !isClosed else { throw SamplingError.closed }
        guard let page = PDFDocument(data: data)?.page(at: 0) else { throw SamplingError.emptyPage }
        drawCount += 1
        samples[theme.id] = (theme, page)
        return page
    }

    /// Releases the web view, its window and temporary file. Later requests fail with `SamplingError.closed`.
    public func close() {
        isClosed = true
        session?.close()
        session = nil
        samples = [:]
    }

    private func openSession() async throws -> Session {
        if let session, session.isReady { return session }
        guard !isClosed else { throw SamplingError.closed }
        // A load that was cancelled or failed leaves a page that is not ready; start again rather than draw it.
        session?.close()
        session = nil
        appliedTheme = nil
        let session = Session(size: printableSize)
        self.session = session
        do {
            try session.load(html, baseURL: baseURL)
            try await WebPaginator.waitUntil(timeout: timeout) { session.navigation.state != .loading }
            if case .failed(let message) = session.navigation.state { throw SamplingError.loadFailed(message) }
            try await WebPaginator.waitForResources(in: session.webView, timeout: timeout)
        } catch {
            session.close()
            if self.session === session { self.session = nil }
            throw error
        }
        session.isReady = true
        return session
    }

    /// Swaps the style sheet and decorations; the document's own JavaScript stays off throughout.
    private func apply(_ theme: PrintTheme, in webView: WKWebView) async throws {
        guard appliedTheme != theme else { return }
        let world = WKContentWorld.world(name: "surimono")
        let swap = """
            const style = document.head.querySelector('style');
            if (style) { style.textContent = css; }
            for (const element of document.querySelectorAll('[data-deco]')) { element.removeAttribute('data-deco'); }
            return document.documentElement.getBoundingClientRect().height;
            """
        _ = try await webView.callAsyncJavaScript(
            swap, arguments: ["css": HTMLDocumentBuilder.styleSheet(theme: theme, textScale: textScale)], in: nil,
            contentWorld: world)
        if let script = theme.script, !script.isEmpty {
            // A failing decoration leaves the page undecorated rather than failing the sample, as in printing.
            _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world)
        }
        appliedTheme = theme
    }

    /// Owns the web view, the window it needs to draw in, and the temporary copy of the document.
    @MainActor
    private final class Session {
        let webView: WKWebView
        let navigation = NavigationTracker()
        /// The document has loaded with its images and fonts, so a theme can be drawn on it.
        var isReady = false
        private let window: NSWindow
        private var temporaryFile: URL?

        init(size: CGSize) {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.suppressesIncrementalRendering = true
            let frame = CGRect(origin: .zero, size: size)
            webView = WKWebView(frame: frame, configuration: configuration)
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            webView.navigationDelegate = navigation
        }

        func load(_ html: String, baseURL: URL?) throws {
            guard let baseURL, baseURL.isFileURL else {
                webView.loadHTMLString(html, baseURL: baseURL)
                return
            }
            // As in pagination: a temporary copy lets images next to the document load. Reading broadly is
            // acceptable only because the page cannot run JavaScript to read and send local files.
            let url = FileManager.default.temporaryDirectory
                .appending(path: "surimono-sample-\(UUID().uuidString).html")
            try Data(WebPaginator.injectingBase(baseURL, into: html).utf8).write(to: url)
            temporaryFile = url
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        func close() {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            temporaryFile = nil
        }
    }
}

extension DocumentRenderer {
    /// A sampler of this document's first page, laid out like its logical pages under `settings`; nil for the
    /// formats that print without a theme.
    public static func themeSampler(for source: DocumentSource, settings: RenderSettings) throws -> ThemeSampler? {
        guard source.format.usesPrintTheme, let fragment = try themedFragment(source) else { return nil }
        // Text formats stand upright unless the paper is turned by hand, as in pagination.
        let layout = settings.layout.oriented(
            settings.layout.kind != .booklet && settings.paperOrientation == .landscape)
        let directory = source.fileURL?.deletingLastPathComponent()
        let html = HTMLDocumentBuilder.build(
            fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
            textScale: settings.textScale)
        return ThemeSampler(
            html: html, baseURL: directory, pageSize: layout.logicalPageSize(options: settings.options),
            margins: .uniform(millimeters: layout.logicalMarginsInMillimeters(options: settings.options)),
            textScale: settings.textScale)
    }
}
