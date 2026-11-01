import AppKit
import PDFKit
import SurimonoCore
import WebKit

/// Draws one document's first page in any print theme, fast enough for a style picker.
///
/// The document is laid out once in an off-screen web view as wide as the printable area of its page, as the
/// paginator lays it out. Each theme then only replaces the page's style sheet and decorations before the first
/// page's area is captured as a vector PDF. A theme with paper (`PaperBackground`) has it drawn by a second web view
/// over the whole page and laid under the text, as in printing. The page is drawn for the screen rather than printed,
/// so it can differ a little from the printed first page; it is a sample for choosing a look, never output.
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

    private let resourceAccess: LocalResourceAccess?
    private let html: String
    private let format: DocumentFormat
    private let baseURL: URL?
    private let textScale: Double
    private let timeout: Duration
    private var session: Session?
    private var paperSession: Session?
    private var appliedTheme: PrintTheme?
    private var appliedHasPaper: Bool?
    private var samples: [String: (theme: PrintTheme, page: PDFPage)] = [:]
    private var isBusy = false
    private var isClosed = false

    /// - Parameter html: A whole document as `HTMLDocumentBuilder` builds it, with exactly one style element.
    public init(
        html: String, format: DocumentFormat = .markdown, baseURL: URL?, pageSize: CGSize,
        margins: WebPaginator.Margins, textScale: Double = 1, timeout: Duration = .seconds(15),
        resourceAccess: LocalResourceAccess? = nil
    ) {
        self.resourceAccess = resourceAccess
        self.html = html
        self.format = format
        self.baseURL = baseURL
        self.pageSize = pageSize
        self.margins = margins
        self.textScale = textScale
        self.timeout = timeout
    }

    /// The sample of `theme`: the whole logical page, with the text of the first page inside its margins and the
    /// theme's paper, if any, under it. Drawn once and then kept until the sampler closes. Requests are served one at
    /// a time.
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
        let hasPaper = try await apply(theme, in: session.webView)
        try Task.checkCancellation()
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: printableSize)
        let data = try await session.webView.pdf(configuration: configuration)
        guard !isClosed else { throw SamplingError.closed }
        guard let text = PDFDocument(data: data)?.page(at: 0) else { throw SamplingError.emptyPage }
        if resourceAccess != nil { LocalResourceSchemeHandler.restoreFileLinks(on: text) }
        // A paper that cannot be drawn leaves the sample on white, as a theme without one.
        let paper = hasPaper && WebPaginator.drawsClearPages ? try? await paperPage(for: theme) : nil
        try Task.checkCancellation()
        guard !isClosed else { throw SamplingError.closed }
        guard let page = PaperComposer.sample(text: text, paper: paper, pageSize: pageSize, margins: margins) else {
            throw SamplingError.emptyPage
        }
        drawCount += 1
        samples[theme.id] = (theme, page)
        return page
    }

    /// Releases the web view, its window and temporary file. Later requests fail with `SamplingError.closed`.
    public func close() {
        isClosed = true
        session?.close()
        session = nil
        paperSession?.close()
        paperSession = nil
        samples = [:]
    }

    private func openSession() async throws -> Session {
        if let session, session.isReady { return session }
        guard !isClosed else { throw SamplingError.closed }
        // A load that was cancelled or failed leaves a page that is not ready; start again rather than draw it.
        session?.close()
        session = nil
        appliedTheme = nil
        appliedHasPaper = nil
        // Clear, so that the paper drawn by the other web view shows through around the text.
        let session = Session(size: printableSize, drawsBackground: false, resourceAccess: resourceAccess, html: html)
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

    /// Swaps the style sheet and decorations; the document's own JavaScript stays off throughout. The page keeps the
    /// paper off with `PaperBackground.removalStyle`; returns whether the theme has paper.
    private func apply(_ theme: PrintTheme, in webView: WKWebView) async throws -> Bool {
        if appliedTheme == theme, let hasPaper = appliedHasPaper { return hasPaper }
        let world = WKContentWorld.world(name: "surimono")
        // A wide page may have kept the previous theme's paper (`PaperBackground.detectionScript`).
        let swap = """
            const style = document.head.querySelector('style');
            if (style) { style.textContent = css; }
            const removal = document.getElementById('\(PaperBackground.removalStyleID)');
            if (removal) { removal.disabled = false; }
            for (const element of document.querySelectorAll('[data-deco]')) { element.removeAttribute('data-deco'); }
            return document.documentElement.getBoundingClientRect().height;
            """
        let css = HTMLDocumentBuilder.styleSheet(theme: theme, textScale: textScale)
        _ = try await webView.callAsyncJavaScript(swap, arguments: ["css": css], in: nil, contentWorld: world)
        // A theme that brings its own fonts starts loading them only now; drawn before they arrive, the sample would
        // show the fallback font and be kept that way.
        if css.contains("@font-face") { try await WebPaginator.waitForResources(in: webView, timeout: timeout) }
        if let script = theme.script, !script.isEmpty {
            // A failing decoration leaves the page undecorated rather than failing the sample, as in printing.
            _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world)
        }
        let detection = try? await webView.callAsyncJavaScript(
            PaperBackground.detectionScript, arguments: [:], in: nil, contentWorld: world)
        let hasPaper = detection as? String == "paper"
        appliedTheme = theme
        appliedHasPaper = hasPaper
        return hasPaper
    }

    /// The theme's paper over the whole page, drawn in a web view of its own that holds only the paper.
    private func paperPage(for theme: PrintTheme) async throws -> PDFPage {
        // The samples are captured at the screen's scale, a pixel to a point.
        let margin = Double(margins.top) * 25.4 / 72
        let css = PaperBackground.styleSheet(
            theme: theme, textScale: textScale, pageSize: pageSize, marginInMillimeters: margin, pixelsPerPoint: 1)
        let session: Session
        if let paperSession, paperSession.isReady {
            session = paperSession
        } else {
            paperSession?.close()
            let html = PaperBackground.document(
                theme: theme, format: format, baseURL: baseURL, textScale: textScale, pageSize: pageSize,
                marginInMillimeters: margin, pixelsPerPoint: 1)
            session = Session(size: pageSize, resourceAccess: resourceAccess, html: html)
            paperSession = session
            do {
                try session.load(html, baseURL: baseURL)
                try await WebPaginator.waitUntil(timeout: timeout) { session.navigation.state != .loading }
                if case .failed(let message) = session.navigation.state { throw SamplingError.loadFailed(message) }
                try await WebPaginator.waitForResources(in: session.webView, timeout: timeout)
            } catch {
                session.close()
                if paperSession === session { paperSession = nil }
                throw error
            }
            session.isReady = true
        }
        let world = WKContentWorld.world(name: "surimono")
        let swap = """
            const style = document.head.querySelector('style');
            if (style) { style.textContent = css; }
            document.documentElement.style.removeProperty('background-color');
            if (document.body) { document.body.style.removeProperty('background-color'); }
            """
        _ = try await session.webView.callAsyncJavaScript(
            swap + "\n" + PaperBackground.opaqueScript, arguments: ["css": css], in: nil, contentWorld: world)
        if css.contains("@font-face") { try await WebPaginator.waitForResources(in: session.webView, timeout: timeout) }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: pageSize)
        let data = try await session.webView.pdf(configuration: configuration)
        guard let page = PDFDocument(data: data)?.page(at: 0) else { throw SamplingError.emptyPage }
        return page
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
        private let resourceAccess: LocalResourceAccess?

        init(
            size: CGSize, drawsBackground: Bool = true, resourceAccess: LocalResourceAccess? = nil, html: String? = nil
        ) {
            self.resourceAccess = resourceAccess
            let configuration = WKWebViewConfiguration()
            if let resourceAccess {
                configuration.setURLSchemeHandler(
                    LocalResourceSchemeHandler(access: resourceAccess, html: html),
                    forURLScheme: LocalResourceSchemeHandler.scheme)
            }
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.suppressesIncrementalRendering = true
            let frame = CGRect(origin: .zero, size: size)
            webView = WKWebView(frame: frame, configuration: configuration)
            if !drawsBackground { WebPaginator.clearBackground?(webView) }
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            webView.navigationDelegate = navigation
        }

        func load(_ html: String, baseURL: URL?) throws {
            if let resourceAccess {
                webView.load(URLRequest(url: LocalResourceSchemeHandler.url(for: resourceAccess.documentURL)))
                return
            }
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
        let access =
            SandboxEnvironment.isSandboxed
            ? source.fileURL.map { LocalResourceAccess(documentURL: $0, folders: source.allowedResourceFolders) } : nil
        guard source.format.usesPrintTheme,
            let fragment = try themedFragment(
                source,
                imageExists: { url in
                    (access?.permits(url) ?? true) && FileManager.default.fileExists(atPath: url.path)
                })
        else { return nil }
        // Text formats stand upright unless the paper is turned by hand, as in pagination.
        let layout = settings.layout.oriented(
            settings.layout.kind != .booklet && settings.paperOrientation == .landscape)
        let directory = source.fileURL?.deletingLastPathComponent()
        let html = HTMLDocumentBuilder.build(
            fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
            textScale: settings.textScale, removesPaper: WebPaginator.drawsClearPages)
        return ThemeSampler(
            html: html, format: source.format, baseURL: directory,
            pageSize: layout.logicalPageSize(options: settings.options),
            margins: .uniform(millimeters: layout.logicalMarginsInMillimeters(options: settings.options)),
            textScale: settings.textScale, resourceAccess: access)
    }
}
