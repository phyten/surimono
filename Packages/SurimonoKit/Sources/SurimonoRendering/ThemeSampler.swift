import AppKit
import PDFKit
import SurimonoCore
import WebKit
import os

/// Draws one document's first page in any print theme, fast enough for a style picker.
///
/// The document is laid out once in an off-screen web view as wide as the printable area of its page, as the
/// paginator lays it out. Each theme then only replaces the page's style sheet and decorations before the first
/// page's area is captured as a vector PDF. A theme with paper (`PaperBackground`) has it drawn by a second web view
/// over the whole page and laid under the text, as in printing. The page is drawn for the screen rather than printed,
/// so it can differ a little from the printed first page; it is a sample for choosing a look, never output.
///
/// A sample can also start at a `SamplePlace` instead of the top: the same area is captured from where that heading or
/// code block stands under the theme. Laying out pages for each theme would take seconds; the column is already there.
@MainActor
public final class ThemeSampler {
    public enum SamplingError: Error, Equatable {
        case loadFailed(String)
        case closed
        case emptyPage
    }

    /// The logical page the samples stand for.
    public let pageSize: CGSize
    public private(set) var margins: WebPaginator.Margins
    private let numericMargins: WebPaginator.Margins
    private var documentMargins: WebPaginator.Margins?
    private var marginMode: LaTeXPageMode?
    private var hasLaTeXMarginInk = false

    public func margins(for theme: PrintTheme) -> WebPaginator.Margins {
        if marginMode?.applies(to: theme) == true, let documentMargins { return documentMargins }
        return numericMargins
    }
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
    private let documentLanguage: String
    private let booklet: Bool
    private let isSourcePage: Bool
    private let format: DocumentFormat
    private let baseURL: URL?
    private let typeface: Typeface
    private let textScale: Double
    private let code: CodeStyle
    private let timeout: Duration
    private var session: Session?
    private var paperSession: Session?
    private var resetsAfterSample = false
    private var appliedTheme: PrintTheme?
    private var appliedHasPaper: Bool?
    /// Kept for as long as the sampler lives, because WebKit drops a world nothing holds, and the next one of that name
    /// starts empty: what a theme's script set up would be gone when the place is measured.
    private let world = WKContentWorld.world(name: "surimono")
    private var samples: [SampleKey: (theme: PrintTheme, page: PDFPage)] = [:]
    private var places: [SamplePlace]?
    private var isBusy = false
    private var isClosed = false

    /// - Parameter html: A whole document as `HTMLDocumentBuilder` builds it, with the theme in its first style element.
    public init(
        html: String, format: DocumentFormat = .markdown, baseURL: URL?, pageSize: CGSize,
        margins: WebPaginator.Margins, booklet: Bool = false, textScale: Double = 1, typeface: Typeface = .style,
        code: CodeStyle = CodeStyle(),
        timeout: Duration = .seconds(15), resourceAccess: LocalResourceAccess? = nil
    ) {
        self.booklet = booklet
        self.resourceAccess = resourceAccess
        self.html = html
        self.documentLanguage = Self.language(in: html)
        self.isSourcePage = format == .plainText && html.contains("<pre class=\"surimono-source ")
        self.format = format
        self.baseURL = baseURL
        self.pageSize = pageSize
        self.margins = margins
        numericMargins = margins
        self.typeface = format.usesPrintTheme ? typeface : .style
        self.textScale = textScale
        self.code = code
        self.timeout = timeout
    }

    fileprivate func configureDocumentMargins(
        _ margins: WebPaginator.Margins?, mode: LaTeXPageMode?, hasMarginInk: Bool
    ) {
        documentMargins = margins
        marginMode = mode
        hasLaTeXMarginInk = hasMarginInk
    }

    private static func language(in html: String) -> String {
        // Generated documents place this attribute before the head, including any embedded font data.
        guard let start = html.range(of: "<html lang=\""),
            let end = html[start.upperBound...].firstIndex(of: "\"")
        else { return "ja" }
        return String(html[start.upperBound..<end])
    }

    // Hash the actual drawing inputs so changes to shared CSS, fonts, code options or decorations cannot reuse
    // an older specimen. Length prefixes keep adjacent fields unambiguous without persisting their contents.
    public func cacheKey(for theme: PrintTheme, language: String, sourceHash: String = "") -> String {
        let effectiveMargins = margins(for: theme)
        let version = theme.flow == .vertical ? "theme-sample-vertical-v3-\(booklet)" : "theme-sample-v4"
        let fields = [
            version, theme.id,
            language, sourceHash, html, format.rawValue,
            HTMLDocumentBuilder.styleSheet(
                theme: theme, textScale: textScale, typeface: typeface, code: code, language: documentLanguage,
                sourcePage: isSourcePage),
            theme.script ?? "",
            String(Double(pageSize.width)), String(Double(pageSize.height)),
            String(Double(effectiveMargins.top)), String(Double(effectiveMargins.left)),
            String(Double(effectiveMargins.bottom)), String(Double(effectiveMargins.right)),
        ]
        let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return ContentHash.of(Data(encoded.utf8)).hex
    }

    private struct SampleKey: Hashable {
        let themeID: String
        let place: SamplePlace?
    }

    /// The sample of `theme`: the whole logical page, with the text of the first page inside its margins and the
    /// theme's paper, if any, under it. Drawn once and then kept until the sampler closes. Requests are served one at
    /// a time.
    public func firstPage(for theme: PrintTheme) async throws -> PDFPage {
        try await page(for: theme, at: nil)
    }

    /// The sample of `theme` starting at `place`, or at the top of the document without one or when the document has no
    /// such place.
    public func page(for theme: PrintTheme, at place: SamplePlace?) async throws -> PDFPage {
        let key = SampleKey(themeID: theme.id, place: place)
        if let sample = samples[key], sample.theme == theme { return sample.page }
        // The web view shows one theme at a time, so a request waits for the one before it.
        try await WebPaginator.waitUntil(timeout: timeout) { !isBusy || isClosed }
        if let sample = samples[key], sample.theme == theme { return sample.page }
        guard !isClosed else { throw SamplingError.closed }
        try Task.checkCancellation()
        let interval = renderingSignposter.beginInterval(
            "themeSample", id: renderingSignposter.makeSignpostID(),
            "format=\(self.format.rawValue, privacy: .public) pages=1")
        defer { renderingSignposter.endInterval("themeSample", interval) }
        isBusy = true
        var succeeded = false
        defer {
            isBusy = false
            if !succeeded || resetsAfterSample { resetSessions() }
        }
        let requestedMargins = margins(for: theme)
        if margins != requestedMargins {
            margins = requestedMargins
            resetSessions()
        }
        var session: Session
        var hasPaper: Bool
        let checksFlow =
            theme.flow == .horizontal && format == .latex
            && (theme.formats == [.latex] || marginMode?.applies(to: theme) == true)
        do {
            let vertical = theme.flow == .vertical && !isSourcePage
            if vertical { resetSessions() }
            session = try await openSession(vertical: vertical)
            try Task.checkCancellation()
            hasPaper = try await apply(theme, in: session.webView)
            var sampleUsesFlow = false
            if checksFlow {
                let protrudes = try await LaTeXFlowPaginator.markVerticalInk(
                    in: session.webView, width: printableSize.width * WebPaginator.printPixelsPerPoint,
                    until: .now + timeout)
                sampleUsesFlow =
                    protrudes || theme.formats == [.latex] && (hasLaTeXMarginInk || LaTeXFlowPaginator.needed(in: html))
            }
            if sampleUsesFlow {
                if html.contains(" data-latex-line-breaking=\"") {
                    try await LaTeXFlowPaginator.installLatinLines(in: session.webView, until: .now + timeout)
                }
                if let place {
                    _ = try await session.webView.evaluateForPrinting(
                        Self.placeElements + "elements[kind][index]?.setAttribute('data-flow-sample-place','')",
                        arguments: ["kind": place.kind.rawValue, "index": place.index], world: world,
                        until: .now + timeout)
                }
                let pass = try await LaTeXFlowPaginator.paginate(
                    in: session.webView, pageSize: pageSize,
                    margins: margins, timeout: timeout, sample: true)
                guard let data = pass.data, let text = StandalonePage.first(of: data) else {
                    throw SamplingError.emptyPage
                }
                if resourceAccess != nil { LocalResourceSchemeHandler.restoreFileLinks(on: text) }
                let paper = hasPaper && WebPaginator.drawsClearPages ? try await paperPage(for: theme) : nil
                guard !isClosed,
                    let page = PaperComposer.sample(
                        text: text, paper: paper, pageSize: pageSize,
                        margins: .uniform(millimeters: 0))
                else { throw SamplingError.emptyPage }
                drawCount += 1
                samples[key] = (theme, page)
                resetSessions()
                succeeded = true
                return page
            }
        } catch {
            try Task.checkCancellation()
            guard !isClosed else { throw SamplingError.closed }
            guard checksFlow else { throw error }
            resetSessions()
            session = try await openSession()
            hasPaper = try await apply(theme, in: session.webView)
        }
        if theme.flow == .vertical && !isSourcePage {
            // Measuring moves the body into a strip. A new session gives the next theme its original DOM.
            defer { resetSessions() }
            let sample = try await VerticalPaginator.pages(
                in: session.webView, pageSize: pageSize, margins: margins, timeout: timeout, booklet: booklet,
                textScale: textScale
            ) { deadline in
                guard let place else { return nil }
                let x = try await session.webView.evaluateForPrinting(
                    Self.placeElements + "const el = elements[kind][index]; return el ? surimonoVerticalX(el) : null;",
                    arguments: ["kind": place.kind.rawValue, "index": place.index], world: self.world,
                    until: deadline)
                return (x as? NSNumber).map { CGFloat(truncating: $0) }
            }
            try session.checkReady()
            guard !isClosed, let page = StandalonePage.first(of: sample) else { throw SamplingError.emptyPage }
            drawCount += 1
            samples[key] = (theme, page)
            return page
        }
        let adjusted = try await WebPaginator.useHorizontalRoot(in: session.webView, timeout: timeout)
        // An inline override for this sample must not hide the next theme’s own root styles.
        defer { if adjusted { resetSessions() } }
        try Task.checkCancellation()
        var top: CGFloat = 0
        if let place { top = try await self.top(of: place, in: session.webView) }
        try Task.checkCancellation()
        let configuration = WKPDFConfiguration()
        var captureSize = printableSize
        var placementMargins = margins
        let usesPaperWidth = format == .latex && theme.formats == [.latex] && marginMode?.applies(to: theme) == true
        if usesPaperWidth {
            // Keep screen samples at their existing pixel scale and measure; only the capture canvas grows.
            _ = try await session.webView.evaluateForPrinting(
                """
                const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
                const s = document.createElement('style');
                s.textContent = `html{width:${width / zoom}px!important;box-sizing:border-box!important;
                  padding-left:${left / zoom}px!important;padding-right:${right / zoom}px!important}`;
                document.head.append(s); globalThis.surimonoSampleCanvas = s;
                """, arguments: ["width": pageSize.width, "left": margins.left, "right": margins.right],
                world: world, until: .now + timeout)
            captureSize.width = pageSize.width
            placementMargins.left = 0
            placementMargins.right = 0
        }
        captureSize.height = try await settledHeight(from: top, height: captureSize.height, in: session.webView)
        configuration.rect = CGRect(origin: CGPoint(x: 0, y: top), size: captureSize)
        let data = try await session.webView.pdfForPrinting(configuration: configuration, until: .now + timeout)
        if usesPaperWidth {
            _ = try await session.webView.evaluateForPrinting(
                "surimonoSampleCanvas.remove(); delete globalThis.surimonoSampleCanvas;",
                arguments: [:], world: world, until: .now + timeout)
        }
        guard !isClosed else { throw SamplingError.closed }
        guard let text = StandalonePage.first(of: data) else { throw SamplingError.emptyPage }
        if resourceAccess != nil { LocalResourceSchemeHandler.restoreFileLinks(on: text) }
        // A missing paper is a failed sample, not a successful white sample to keep in the cache.
        let paper = hasPaper && WebPaginator.drawsClearPages ? try await paperPage(for: theme) : nil
        try Task.checkCancellation()
        guard !isClosed else { throw SamplingError.closed }
        try session.checkReady()
        guard let page = PaperComposer.sample(text: text, paper: paper, pageSize: pageSize, margins: placementMargins)
        else {
            throw SamplingError.emptyPage
        }
        drawCount += 1
        samples[key] = (theme, page)
        succeeded = true
        return page
    }

    /// The headings and code blocks a sample can start at, in the order of the document within each kind.
    public func places() async throws -> [SamplePlace] {
        if let places { return places }
        try await WebPaginator.waitUntil(timeout: timeout) { !isBusy || isClosed }
        if let places { return places }
        guard !isClosed else { throw SamplingError.closed }
        try Task.checkCancellation()
        isBusy = true
        var succeeded = false
        defer {
            isBusy = false
            if !succeeded { resetSessions() }
        }
        let session = try await openSession()
        let json = try await session.webView.evaluateForPrinting(
            Self.placeElements + Self.listing, arguments: [:], world: world, until: .now + timeout)
        let found = try JSONDecoder().decode([SamplePlace].self, from: Data((json as? String ?? "[]").utf8))
        try Task.checkCancellation()
        try session.checkReady()
        places = found
        succeeded = true
        return found
    }

    /// Where `place` starts under the theme in the web view, in the web view's points; the top without such a place.
    private func top(of place: SamplePlace, in webView: WKWebView) async throws -> CGFloat {
        let top = try await webView.evaluateForPrinting(
            Self.placeElements + Self.unscaling + Self.locating,
            arguments: ["kind": place.kind.rawValue, "index": place.index, "lead": Self.placeLead], world: world,
            until: .now + timeout)
        return (top as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }

    /// The height of the capture from `top` that ends between lines: a line of text, an image or a diagram the bottom
    /// edge would cut through is left out, and the paper stays blank below the last whole one. A figure taller than
    /// the sample is cut at the bottom as before, and so is the whole sample when moving the edge up would keep
    /// nothing but the space above what it left out.
    private func settledHeight(from top: CGFloat, height: CGFloat, in webView: WKWebView) async throws -> CGFloat {
        let settled = try await webView.evaluateForPrinting(
            Self.unscaling + Self.settling, arguments: ["top": top, "height": height], world: world,
            until: .now + timeout)
        return (settled as? NSNumber).map { CGFloat(truncating: $0) } ?? height
    }

    /// Room kept above a place, out of its own margin, so that a border or a shadow on the element is not cut.
    private static let placeLead = 8

    /// Listing and finding places share this, so that a place's index means the same to both. Text is read as
    /// `DocumentOutline` reads it, and a `pre` without `code` is plain text or a diagram's source.
    private static let placeElements = """
        const readable = (element) => {
            const copy = element.cloneNode(true);
            for (const hidden of copy.querySelectorAll('rt, rp, svg, math')) { hidden.remove(); }
            return copy.textContent.replace(/\\s+/g, ' ').trim();
        };
        const elements = {
            heading: [...document.querySelectorAll('h1, h2, h3, h4, h5, h6')].filter((heading) => readable(heading)),
            code: [...document.querySelectorAll('pre > code')].map((code) => code.parentElement),
        };

        """

    private static let listing = """
        const firstLine = (block) => {
            const numbered = [...block.querySelectorAll('.code-src')].map((line) => line.textContent);
            const lines = numbered.length > 0 ? numbered : block.textContent.split('\\n');
            return (lines.find((line) => line.trim()) ?? '').trim();
        };
        return JSON.stringify([
            ...elements.heading.map((heading, index) => ({
                kind: 'heading', index, level: Number(heading.tagName.slice(1)), title: readable(heading),
            })),
            ...elements.code.map((block, index) => ({ kind: 'code', index, title: firstLine(block) }))
                .filter((place) => place.title),
        ]);
        """

    /// The text size is a CSS zoom on the root. Rectangles include it from Safari 26.4 on and leave it out before, so a
    /// box of a known height tells which this WebKit does. Inline `!important` keeps the document's and the reader's
    /// styles off the box, which would change its height and throw every place off.
    private static let unscaling = """
        const probe = document.createElement('surimono-probe');
        probe.style.cssText = `all: initial !important; display: block !important; position: absolute !important;
            height: 100px !important; visibility: hidden !important;`;
        document.documentElement.append(probe);
        const reported = probe.getBoundingClientRect().height / 100;
        probe.remove();
        const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
        const unscaled = reported > 0 ? zoom / reported : 1;

        """

    private static let locating = """
        const element = elements[kind][index];
        if (!element) { return 0; }
        const margin = parseFloat(getComputedStyle(element).marginTop) || 0;
        const top = (element.getBoundingClientRect().top + window.scrollY) * unscaled;
        return Math.max(top - Math.min(margin, lead), 0);
        """

    /// Moves the bottom edge up above anything it would cut, again and again, since a line moved out of the sample
    /// may bring the edge into the line above it.
    private static let settling = """
        const toPoints = (box) => ({ top: (box.top + window.scrollY) * unscaled,
            bottom: (box.bottom + window.scrollY) * unscaled });
        // A figure taller than the whole sample has no place to end between lines; it is cut at the bottom as it was,
        // and the text inside it does not move the edge either.
        const figures = [...document.body.querySelectorAll('img, svg, canvas, video, iframe, object, embed')];
        const tall = figures.filter((figure) => {
            const span = toPoints(figure.getBoundingClientRect());
            return span.bottom - span.top > height;
        });
        const inTall = (node) => tall.some((figure) => figure.contains(node));
        const boxes = [];
        const range = document.createRange();
        const start = top / unscaled - window.scrollY;
        const edge = (top + height) / unscaled - window.scrollY;
        // Only the boxes within the sample matter; a document's other pages are skipped a block at a time.
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                if (node.nodeType === Node.TEXT_NODE) { return NodeFilter.FILTER_ACCEPT; }
                if (tall.includes(node)) { return NodeFilter.FILTER_REJECT; }
                const box = node.getBoundingClientRect();
                const outside = box.height > 0 && (box.bottom < start - 1 || box.top > edge + 1)
                    && getComputedStyle(node).position === 'static';
                return outside ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
            },
        });
        while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.data.trim()) { continue; }
            range.selectNodeContents(node);
            boxes.push(...range.getClientRects());
        }
        for (const figure of figures) {
            if (!inTall(figure)) { boxes.push(figure.getBoundingClientRect()); }
        }
        const spans = boxes.map(toPoints).filter((span) => span.bottom > span.top);
        let cut = top + height;
        for (let pass = 0; pass < 200; pass += 1) {
            let next = cut;
            for (const span of spans) {
                if (span.top >= top && span.top < next - 0.5 && span.bottom > next + 0.5) { next = span.top; }
            }
            if (next === cut) { break; }
            cut = next;
        }
        if (cut === top + height) { return height; }
        // Moving the edge up must keep something whole above it, not only the space before what it left out.
        const kept = spans.some((span) => span.bottom > top + 0.5 && span.bottom <= cut + 0.5 && span.top < cut);
        const keptFigure = tall.some((figure) => {
            const span = toPoints(figure.getBoundingClientRect());
            return span.top < cut && span.bottom > top;
        });
        return kept && !keptFigure ? cut - top : height;
        """

    /// Releases the web view, its window and temporary file. Later requests fail with `SamplingError.closed`.
    public func close() {
        isClosed = true
        resetSessions()
        samples = [:]
        places = nil
    }

    private func resetSessions() {
        resetsAfterSample = false
        session?.close()
        session = nil
        paperSession?.close()
        paperSession = nil
        appliedTheme = nil
        appliedHasPaper = nil
    }

    @concurrent private static func verticalHTML(_ html: String, latex: Bool) async throws -> String {
        try Task.checkCancellation()
        let marked = try VerticalText.marked(html, latex: latex)
        try PageLayoutLimits.checkHTML(bytes: marked.utf8.count, sourceBytes: html.utf8.count)
        return marked
    }

    private func openSession(vertical: Bool = false) async throws -> Session {
        if let session, session.isReady { return session }
        guard !isClosed else { throw SamplingError.closed }
        // A load that was cancelled or failed leaves a page that is not ready; start again rather than draw it.
        session?.close()
        session = nil
        appliedTheme = nil
        appliedHasPaper = nil
        // Clear, so that the paper drawn by the other web view shows through around the text.
        let html = vertical ? try await Self.verticalHTML(self.html, latex: format == .latex) : self.html
        try Task.checkCancellation()
        guard !isClosed else { throw SamplingError.closed }
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
        if format.usesPrintTheme {
            try await DiagramScript.prepare(in: session.webView, height: printableSize.height) { script in
                try await session.webView.evaluateForPrinting(
                    script, arguments: [:], world: self.world, until: .now + self.timeout)
                    as? String
            }
        }
        session.didLoadResources = true
        try session.checkReady()
        return session
    }

    /// Swaps the style sheet and decorations; the document's own JavaScript stays off throughout. The page keeps the
    /// paper off with `PaperBackground.removalStyle`; returns whether the theme has paper.
    private func apply(_ theme: PrintTheme, in webView: WKWebView) async throws -> Bool {
        if appliedTheme == theme, let hasPaper = appliedHasPaper { return hasPaper }
        // A cancelled swap must not leave the previous theme marked as applied.
        appliedTheme = nil
        appliedHasPaper = nil
        // A wide page may have kept the previous theme's paper (`PaperBackground.detectionScript`).
        let swap = """
            const style = document.head.querySelector('style');
            if (style) { style.textContent = css; }
            const removal = document.getElementById('\(PaperBackground.removalStyleID)');
            if (removal) { removal.disabled = false; }
            for (const element of document.querySelectorAll('[data-deco]')) { element.removeAttribute('data-deco'); }
            return document.documentElement.getBoundingClientRect().height;
            """
        var css = HTMLDocumentBuilder.styleSheet(
            theme: theme, textScale: textScale, typeface: typeface, code: code, language: documentLanguage,
            sourcePage: isSourcePage)
        if documentMargins != nil, theme.formats == [.latex] || marginMode?.applies(to: theme) == true {
            css += RenderSettings.documentWidthCSS
        }
        _ = try await webView.evaluateForPrinting(swap, arguments: ["css": css], world: world, until: .now + timeout)
        // A theme that brings its own fonts starts loading them only now; drawn before they arrive, the sample would
        // show the fallback font and be kept that way.
        if css.contains("@font-face") { try await WebPaginator.waitForResources(in: webView, timeout: timeout) }
        if format == .latex,
            let script = LaTeXGraphicPreparation.script(
                in: html, layoutWidth: printableSize.width,
                layoutHeight: theme.formats == [.latex] ? printableSize.height : nil)
        {
            _ = try await webView.evaluateForPrinting(script, arguments: [:], world: world, until: .now + timeout)
        }
        // Optional decorations can fail normally. A timed-out script might still change the DOM after
        // this theme, so discard its session before reusing the view for another sample.
        let fitsCode = theme.flow != .vertical || isSourcePage
        for script in [
            fitsCode ? CodeFitScript.javaScript(for: code, layoutWidth: printableSize.width) : nil, theme.script,
        ] {
            guard let script, !script.isEmpty else { continue }
            do {
                _ = try await webView.evaluateForPrinting(script, world: world, until: .now + timeout)
            } catch WebPaginator.PaginationError.timedOut {
                throw WebPaginator.PaginationError.timedOut
            } catch {
                try Task.checkCancellation()
            }
        }
        let flow: PrintFlow = theme.flow == .vertical && !isSourcePage ? .vertical : .horizontal
        if TableFit.applies(to: format, flow: flow, theme: theme, latexMargins: marginMode, body: html) {
            // Fitted at the sample's own layout width, as the print fits them at its width. The fitted tables
            // belong to this theme, so the next theme starts from a fresh page.
            resetsAfterSample = try await TableFit.fit(in: webView, width: nil, until: .now + timeout)
        }
        let detection = try await webView.evaluateForPrinting(
            PaperBackground.detectionScript, arguments: [:], world: world, until: .now + timeout)
        try Task.checkCancellation()
        let hasPaper = detection as? String == "paper"
        appliedTheme = theme
        appliedHasPaper = hasPaper
        return hasPaper
    }

    /// The theme's paper over the whole page, drawn in a web view of its own that holds only the paper.
    private func paperPage(for theme: PrintTheme) async throws -> PDFPage {
        // The samples are captured at the screen's scale, a pixel to a point.
        func millimeters(_ points: CGFloat) -> Double { Double(points) * 25.4 / 72 }
        let paperMargins = PageMargins(
            top: millimeters(margins.top), left: millimeters(margins.left), bottom: millimeters(margins.bottom),
            right: millimeters(margins.right))
        let css = PaperBackground.styleSheet(
            theme: theme, textScale: textScale, typeface: typeface, pageSize: pageSize, margins: paperMargins,
            pixelsPerPoint: 1,
            language: documentLanguage)
        let session: Session
        if let paperSession, paperSession.isReady {
            session = paperSession
        } else {
            paperSession?.close()
            let html = PaperBackground.document(
                theme: theme, format: format, baseURL: baseURL, language: documentLanguage, textScale: textScale,
                typeface: typeface,
                pageSize: pageSize,
                margins: paperMargins, pixelsPerPoint: 1)
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
            session.didLoadResources = true
            try session.checkReady()
        }
        let swap = """
            const style = document.head.querySelector('style');
            if (style) { style.textContent = css; }
            document.documentElement.style.removeProperty('background-color');
            if (document.body) { document.body.style.removeProperty('background-color'); }
            """
        _ = try await session.webView.evaluateForPrinting(
            swap + "\n" + PaperBackground.opaqueScript, arguments: ["css": css], world: world, until: .now + timeout)
        if css.contains("@font-face") { try await WebPaginator.waitForResources(in: session.webView, timeout: timeout) }
        let configuration = WKPDFConfiguration()
        let adjusted = try await WebPaginator.useHorizontalRoot(in: session.webView, timeout: timeout)
        defer {
            if adjusted {
                session.close()
                paperSession = nil
            }
        }
        configuration.rect = CGRect(origin: .zero, size: pageSize)
        let data = try await session.webView.pdfForPrinting(configuration: configuration, until: .now + timeout)
        try Task.checkCancellation()
        try session.checkReady()
        guard let page = StandalonePage.first(of: data) else { throw SamplingError.emptyPage }
        return page
    }

    /// Owns the web view, the window it needs to draw in, and the temporary copy of the document.
    @MainActor
    private final class Session {
        let webView: WKWebView
        let navigation = NavigationTracker()
        /// The document has loaded with its images and fonts, so a theme can be drawn on it.
        var didLoadResources = false
        var isReady: Bool { didLoadResources && navigation.state == .finished }

        func checkReady() throws {
            if case .failed(let message) = navigation.state { throw SamplingError.loadFailed(message) }
            guard isReady else { throw SamplingError.closed }
        }
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
            // acceptable only because the page cannot run JavaScript to read and send local files and cannot load
            // them as documents.
            let url = FileManager.default.temporaryDirectory
                .appending(path: "surimono-sample-\(UUID().uuidString).html")
            try Data(WebPaginator.injectingBase(baseURL, into: html).utf8).write(to: url)
            temporaryFile = url
            navigation.generatedPageURL = url
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        func close() {
            didLoadResources = false
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
        try samplerFactory(for: source, settings: settings, removesPaper: WebPaginator.drawsClearPages)?()
    }

    @concurrent public static func prepareThemeSampler(
        for source: DocumentSource, settings: RenderSettings, removesPaper: Bool
    )
        async throws -> ThemeSampler?
    {
        let make = try samplerFactory(for: source, settings: settings, removesPaper: removesPaper)
        try Task.checkCancellation()
        return await make?()
    }

    private nonisolated static func samplerFactory(
        for source: DocumentSource, settings: RenderSettings, removesPaper: Bool
    )
        throws -> (@Sendable @MainActor () -> ThemeSampler)?
    {
        if let children = source.children {
            guard let first = children.first(where: { $0.format.usesPrintTheme }) else { return nil }
            return try samplerFactory(for: first, settings: settings, removesPaper: removesPaper)
        }
        let access =
            SandboxEnvironment.isSandboxed
            ? source.fileURL.map { LocalResourceAccess(documentURL: $0, folders: source.allowedResourceFolders) } : nil
        // Text formats stand upright unless the paper is turned by hand, as in pagination.
        let layout = settings.layout.oriented(
            settings.layout.kind != .booklet && settings.paperOrientation == .landscape)
        guard source.format.usesPrintTheme,
            let fragment = try themedFragment(
                source, pageBreakLine: settings.finish.breaks.customLine, proof: settings.finish.proof,
                orgReading: settings.orgReading, readingSettings: settings.readingSettings,
                composition: settings.theme.formats == [.latex] ? settings.latexComposition : .document,
                textWidthPoints: settings.textWidthPoints(in: layout), textScale: settings.textScale, access: access,
                imageExists: { url in
                    (access?.permits(url) ?? true) && FileManager.default.fileExists(atPath: url.path)
                })
        else { return nil }
        let directory = source.fileURL?.deletingLastPathComponent()
        let html = try HTMLDocumentBuilder.build(
            fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
            language: settings.pageLanguage,
            textScale: settings.textScale, typeface: settings.typeface, removesPaper: removesPaper,
            finish: settings.finish.styleSheet, code: settings.code, preparesThemeSampler: true,
            checkSourceBytes: { try PageLayoutLimits.checkHTML(bytes: $0, sourceBytes: source.data.count) })
        try PageLayoutLimits.checkHTML(bytes: html.utf8.count, sourceBytes: source.data.count)
        // A slide specimen already carries its own paper and text margins, just like the printed deck.
        let slideSize = fragment.latexClass?.beamerPageSize
        let size = slideSize ?? layout.logicalPageSize(options: settings.options)
        let box = slideSize != nil || layout.kind == .handout3 ? nil : fragment.latexClass?.pageBox
        let hasMarginInk = source.format == .latex && LaTeXFlowPaginator.hasMarginInk(in: fragment.body)
        return {
            let sampler = ThemeSampler(
                html: html, format: source.format, baseURL: directory,
                pageSize: size,
                margins: WebPaginator.Margins(
                    slideSize == nil ? layout.logicalMargins(options: settings.options) : .zero),
                booklet: layout.kind == .booklet, textScale: settings.textScale, typeface: settings.typeface,
                code: settings.code, resourceAccess: access)
            sampler.configureDocumentMargins(
                box.map { WebPaginator.Margins($0.margins(fitting: size)) }, mode: settings.options.latexMargins,
                hasMarginInk: hasMarginInk)
            return sampler
        }
    }

    /// Whether the document has code that the code palette and the block's options would change.
    nonisolated public static func containsCode(_ source: DocumentSource) -> Bool {
        if let children = source.children { return children.contains(where: containsCode) }
        guard source.format.usesPrintTheme, let fragment = try? themedFragment(source) else { return false }
        return CodeBlockMarkup.containsCode(fragment.body)
    }
}
