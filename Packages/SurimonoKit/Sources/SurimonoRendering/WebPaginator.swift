import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import UniformTypeIdentifiers
import WebKit

/// Lays out HTML in an off-screen WKWebView and prints it into a paginated PDF.
@MainActor
public final class WebPaginator: NSObject {
    /// Whether the paper may go on to another document: only a document opened from a file, never generated HTML,
    /// a live page's copy or a page from memory.
    static func followsOtherDocuments(_ source: Source) -> Bool {
        switch source {
        case .file: true
        case .sandboxed(_, _, let follows): follows
        case .html, .snapshot: false
        }
    }

    public enum Source: Sendable {
        case html(String, baseURL: URL?)
        /// A page read through the sandbox's resource handler. `followsOtherDocuments` is decided from the original
        /// document before it became this source: an opened HTML file may go on to another document within its
        /// access, as it always could; HTML generated from Markdown and the other formats never does.
        case sandboxed(String?, access: LocalResourceAccess, followsOtherDocuments: Bool = false)
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

        public init(_ margins: PageMargins) {
            func points(_ millimeters: Double) -> CGFloat { CGFloat(millimeters * 72 / 25.4) }
            self.init(
                top: points(margins.top), left: points(margins.left), bottom: points(margins.bottom),
                right: points(margins.right))
        }

        public static func uniform(millimeters: Double) -> Margins { Margins(.uniform(millimeters)) }

        /// The margins of a left-hand page, whose outer side is on the left.
        public var mirrored: Margins { Margins(top: top, left: right, bottom: bottom, right: left) }
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
        public var requiredFolderAccess: URL?
        public var issues: [PrintIssue] = []
        public var exportedHTML: String?
        var diagramPass: DiagramGeometry.Pass?
        var diagrams: [RenderedDiagram] = []
        var richTextFigures: [RichTextFigure] = []
        /// What the renderer added to the pages of a text and read from it.
        var finishing = FinishedPages()
        var drawingBytes: Data?

        public init(
            document: PDFDocument, preparationResult: String? = nil, pageRules: [PageRule] = [],
            requiredFolderAccess: URL? = nil
        ) {
            self.requiredFolderAccess = requiredFolderAccess
            self.document = document
            self.preparationResult = preparationResult
            self.pageRules = pageRules
        }
    }

    /// Upper bound for the print step, which normally finishes in well under a second.
    var printTimeout: Duration?
    var flowEvaluator: LaTeXFlowPaginator.Evaluator?
    var inspectFlowPlan: LaTeXFlowPaginator.PlanObserver?
    // Test clients opt into paragraph text only when comparing the corpus or checking PDF output.
    var collectsLatinLineDiagnostics = false
    var collectsLatinBoxDiagnostics = false
    private(set) var latinLineRoute: String?
    private(set) var latinLinePasses: [String] = []
    private(set) var latinLineDiagnostics: String?

    /// Sessions whose web view and temporary files have not been released yet (observed by tests).
    private(set) var openSessionCount = 0
    /// Number of print operations started (observed by tests).
    private(set) var printStartCount = 0
    /// Test hooks that make the order of events around printing deterministic.
    // Tests can deliver the navigation deadline once a committed document reaches a particular parser state.
    var expireNavigationAfterCommit: (@MainActor (WKWebView) async throws -> Void)?
    var didStartWaitingForResources: (@MainActor () -> Void)?
    var didFinishPrinting: (@MainActor () -> Void)?
    /// Lets layout tests read the prepared DOM before starting the native print operation.
    var inspectPrintLayout: (@MainActor (WKWebView) async -> Void)?
    /// Receives the web view of a session as it starts to print (a test ends that page's process there).
    var didStartPrinting: (@MainActor (WKWebView) -> Void)?
    /// Receives the web view of a session as it starts to serialize an HTML export (a test ends its process there).
    var didStartExporting: (@MainActor (WKWebView) -> Void)?
    /// Receives whether the document may draw below the paper (observed by tests).
    var didCheckPageRules: (@MainActor (Bool) -> Void)?

    /// One retained world: a world made by each `.world(name:)` call can be released between calls, which drops the
    /// globals a library loaded in one preparation call leaves for the next.
    static let preparationWorld = WKContentWorld.world(name: "surimono")

    /// Observed by tests to keep documents without diagrams free of the library load.
    private(set) var mermaidLoadCount = 0

    public override init() {}

    /// CSS pixels to a point of the printed page. WebKit lays a page out 1.25 times as wide as its paper and shrinks
    /// it to fit (a page wider than that shrinks further).
    public static let printPixelsPerPoint = 1.25

    // Only the distribution app may opt into platform-specific background removal.
    public static var clearBackground: (@MainActor (WKWebView) -> Void)?
    public static var drawsClearPages: Bool { clearBackground != nil }

    /// Keep one small SVG per hit. Embed the binary font programs only for the formula being exported.
    public static func exportSVG(_ graphic: RenderedDiagram) -> String {
        guard graphic.formulaSource != nil, let end = graphic.svg.range(of: "</title>") else { return graphic.svg }
        let css = MathRenderer.fontFaces(for: String(graphic.svg[end.upperBound...]))
        var svg = graphic.svg
        svg.insert(contentsOf: "<style>\(css)</style>", at: end.upperBound)
        if let root = svg.range(of: "<svg ") {
            svg.insert(
                contentsOf: "width=\"\(graphic.pointSize.width)pt\" height=\"\(graphic.pointSize.height)pt\" ",
                at: root.upperBound)
        }
        return svg
    }

    /// Load the SVG as an image so its text is rasterized at export scale on a plain white background.
    public static func diagramPNG(_ diagram: RenderedDiagram) async throws -> Data {
        let size = diagram.pointSize
        var scale: CGFloat = 3
        if diagram.formulaSource != nil, size.height > 0 {
            scale = max(3, min(96 / size.height, 12000 / max(size.width, size.height)))
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            (size.width * scale).rounded(.up) * (size.height * scale).rounded(.up) <= 12_000 * 12_000
        else { throw PaginationError.emptyDocument }
        let image = Data(exportSVG(diagram).utf8).base64EncodedString()
        let html = """
            <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'">
            <style>*{margin:0}body{background:white}img{display:block;width:\(size.width)px;height:\(size.height)px}</style>
            <img src="data:image/svg+xml;base64,\(image)">
            """
        let source = Source.html(html, baseURL: nil)
        let session = PaginationSession(
            source: source, pageSize: size, margins: .uniform(millimeters: 0), allowsJavaScript: false,
            printsBackgrounds: true, printTimeout: .seconds(15), onPrintStart: { _ in }, onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        try session.load(source)
        try await waitUntil(timeout: .seconds(15)) {
            session.navigationState != .loading || session.terminationError != nil
        }
        if let message = session.terminationError { throw PaginationError.loadFailed(message) }
        guard session.navigationState == .finished,
            try await session.webView.evaluateForPrinting(
                "const image = document.images[0]; await image.decode(); return image.naturalWidth > 0;",
                until: .now + .seconds(15)) as? Bool == true
        else { throw PaginationError.emptyDocument }
        try Task.checkCancellation()
        let bounds = CGRect(origin: .zero, size: size)
        return try await WebGraphicSnapshot(requestedScale: scale).png(
            in: session.webView, viewport: bounds, document: bounds, until: .now + .seconds(15))
    }

    public func paginate(
        _ source: Source, pageSize: CGSize, margins: Margins, allowsJavaScript: Bool,
        printsBackgrounds: Bool = true, preparationScript: String? = nil, timeout: Duration? = nil
    ) async throws -> PDFDocument {
        try await paginateWithResult(
            source, pageSize: pageSize, margins: margins, allowsJavaScript: allowsJavaScript,
            printsBackgrounds: printsBackgrounds, preparationScript: preparationScript, timeout: timeout
        ).document
    }

    public struct HTMLComposition: Sendable {
        var versoShift: CGFloat
        var rightBound: Bool
    }

    /// Returns the preparation script's string result together with the PDF made from that same DOM.
    /// - Parameters:
    ///   - readsPageRules: Whether to read the document's `@page` rules into the result.
    ///   - drawsBackground: Whether WebKit's white goes under a page without a background of its own; false leaves
    ///     such a page clear where `drawsClearPages` allows it.
    public func paginateWithResult(
        _ source: Source, pageSize: CGSize, margins: Margins, allowsJavaScript: Bool,
        printsBackgrounds: Bool = true, preparationScript: String? = nil, readsPageRules: Bool = false,
        drawsBackground: Bool = true, rendersMermaid: Bool = false, rendersDiagrams: Bool = false,
        collectsDiagrams: Bool = false, indexesFormulas: Bool = false, exportHTMLTitle: String? = nil,
        richText: Bool = false,
        richTextTypeface: Typeface = .style, htmlComposition: HTMLComposition? = nil,
        latexPageNumbers: LaTeXPageNumbers? = nil, restartsAfterTitle: Bool = false,
        composesLaTeXParagraphs: Bool = false, latexFlow: Bool = false, latexMarginInk: Bool = false,
        checksVerticalLaTeXInk: Bool = false,
        flow: PrintFlow = .horizontal, timeout: Duration? = nil
    ) async throws -> Result {
        let bytes: Int
        var nativeLaTeXBreaks = false
        var composesLatin = false
        var requiresProofLines = false
        latinLineRoute = nil
        latinLinePasses.removeAll()
        latinLineDiagnostics = nil
        switch source {
        case .html(let html, _), .snapshot(let html, _), .sandboxed(.some(let html), _, _):
            bytes = html.utf8.count
            requiresProofLines = latexFlow && html.contains(" data-latex-review=\"proofPageLines\"")
            composesLatin =
                (composesLaTeXParagraphs || latexFlow) && flow == .horizontal && !allowsJavaScript
                && html.contains(" data-latex-line-breaking=\"")
            nativeLaTeXBreaks = !latexFlow && html.contains("class=\"latex-pagebreak\"")
        case .file(let url, _): bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        case .sandboxed(nil, let access, _):
            bytes = (try? access.documentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let timeout = timeout ?? PageLayoutLimits.timeout(bytes: bytes, baseSeconds: 15)
        let printTimeout = printTimeout ?? PageLayoutLimits.timeout(bytes: bytes, baseSeconds: 60)
        openSessionCount += 1
        let session = PaginationSession(
            source: source, pageSize: pageSize, margins: margins, allowsJavaScript: allowsJavaScript,
            printsBackgrounds: printsBackgrounds, drawsBackground: drawsBackground, printTimeout: printTimeout,
            onPrintStart: { [weak self] webView in
                self?.printStartCount += 1
                self?.didStartPrinting?(webView)
            },
            onPrintFinish: { [weak self] in self?.didFinishPrinting?() },
            onClose: { [weak self] in self?.openSessionCount -= 1 })
        // Closing is deferred to the print completion while the print thread still uses the session.
        defer { session.requestClose() }

        if exportHTMLTitle != nil {
            let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "SurimonoOfflineExport",
                encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#)
            guard let rules else { throw PaginationError.loadFailed("Offline export is unavailable.") }
            session.webView.configuration.userContentController.add(rules)
        }
        let stoppedResources: Bool
        do {
            stoppedResources = try await session.loadForPrinting(
                source, timeout: timeout, expireAfterCommit: expireNavigationAfterCommit)
        } catch {
            return try await retrySingleColumn(after: error, usedFlow: latexFlow)
        }
        didStartWaitingForResources?()
        // The stopped resources never report back, so the full wait would only be spent a second time.
        try await Self.waitForResources(
            in: session.webView, timeout: stoppedResources ? min(timeout, .seconds(1)) : timeout)
        let pageRules: [PageRule]
        let preparationResult: String?
        do {
            if collectsDiagrams {
                // Keep the engine-created nodes in the isolated world without marking the printable DOM.
                _ = try await runPreparationScript(
                    "globalThis.surimonoRenderedDiagrams = new Set();", in: session.webView, timeout: timeout)
            }
            if rendersMermaid,
                let countText = try await runPreparationScript(
                    MermaidScript.probe, in: session.webView, timeout: timeout),
                let count = Int(countText), count > 0
            {
                try await prepareMermaid(in: session.webView, count: count, timeout: timeout)
            }
            if rendersDiagrams {
                try await DiagramScript.prepare(
                    in: session.webView,
                    height: (pageSize.height - margins.top - margins.bottom) * Self.printPixelsPerPoint
                ) { script in
                    try await self.runPreparationScript(script, in: session.webView, timeout: timeout)
                }
            }
            // Before the preparation, whose presets may remove the document's style elements.
            pageRules =
                readsPageRules
                ? PageRule.rules(
                    fromJSON: try await runPreparationScript(PageRule.javaScript, in: session.webView, timeout: timeout)
                        ?? "")
                : []
            if let preparationScript, !preparationScript.isEmpty {
                if checksVerticalLaTeXInk || latexFlow {
                    _ = try await runPreparationScript(
                        "globalThis.surimonoDefersMarks = true", in: session.webView, timeout: timeout)
                }
                preparationResult = try await runPreparationScript(
                    preparationScript, in: session.webView, timeout: timeout)
            } else {
                preparationResult = nil
            }
        } catch {
            return try await retrySingleColumn(after: error, usedFlow: latexFlow)
        }
        try Task.checkCancellation()
        if let exportHTMLTitle {
            let adjusted = try await Self.useHorizontalRootForOutput(in: session.webView, timeout: timeout)
            if let htmlComposition {
                if composesLatin {
                    try await LaTeXFlowPaginator.installLatinLines(in: session.webView, until: .now + timeout)
                }
                _ = try await LaTeXFlowPaginator.paginate(
                    in: session.webView, pageSize: pageSize, margins: margins, timeout: printTimeout,
                    htmlComposition: htmlComposition)
                try await Self.waitForResources(in: session.webView, timeout: timeout)
            }
            if richText { try await RichTextGraphics.replace(in: session.webView, until: .now + printTimeout) }
            didStartExporting?(session.webView)
            let imageURLs =
                try await session.webView.evaluateForPrinting(
                    HTMLExporter.imageResourceScript, until: .now + printTimeout) as? [String] ?? []
            var images: [String: String] = [:]
            for address in Set(imageURLs) {
                guard let url = URL(string: address) else { continue }
                let bytes: Data
                let mime: String
                if let handler = session.localHandler, url.scheme == LocalResourceSchemeHandler.scheme {
                    let resource = try handler.resource(at: url)
                    bytes = resource.data
                    mime = resource.mimeType
                } else if url.isFileURL, session.localHandler == nil {
                    bytes = try Data(contentsOf: url)
                    mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                } else {
                    continue
                }
                images[address] = "data:" + mime + ";base64," + bytes.base64EncodedString()
            }
            let copiesTypeface = richText && richTextTypeface == .latex
            let bundledFonts = copiesTypeface ? ThemeFonts.textFamilies : []
            let serialized =
                try await session.webView.evaluateForPrinting(
                    HTMLExporter.serializationScript,
                    arguments: [
                        "title": exportHTMLTitle, "embeddedImages": images, "richText": richText,
                        "systemFonts": richText ? RichTextExport.systemFonts + bundledFonts : [],
                        "copiesTypeface": copiesTypeface, "composedHTML": htmlComposition != nil,
                        "pasteCSS": RichTextExport.styleSheet + (copiesTypeface ? "\n" + ThemeFonts.textFaces : ""),
                    ],
                    // Given the print's time: the export takes the place of the print.
                    until: .now + printTimeout)
            var result = Result(document: PDFDocument())
            if adjusted { result.issues = [Self.verticalWritingIssue] }
            if richText, let fields = serialized as? [String: Any], let html = fields["html"] as? String,
                let figures = fields["figures"] as? [[String: Any]]
            {
                result.exportedHTML = html
                result.richTextFigures = try figures.map { try RichTextFigure(fields: $0) }
            } else if let html = serialized as? String {
                result.exportedHTML = html
            } else {
                throw PaginationError.emptyDocument
            }
            return result
        }
        let indexToken = UUID().uuidString
        func installFormulaIndex() async throws {
            guard let url = Bundle.module.url(forResource: "formula-index", withExtension: "js") else {
                throw PaginationError.loadFailed("formula-index")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            _ = try await session.webView.evaluateForPrinting(
                DiagramGeometry.placeAnchors + "\n" + LaTeXGraphicPreparation.glyphInk + "\n" + script,
                arguments: ["token": indexToken], until: .now + timeout)
        }
        func formulaPass(_ document: PDFDocument) async throws -> DiagramGeometry.Pass {
            guard
                let json = try await runPreparationScript(
                    "return JSON.stringify(surimonoFormulaIndex.sources)", in: session.webView, timeout: timeout)
            else { throw PaginationError.printFailed }
            let sources = try JSONDecoder().decode([DiagramGeometry.Source].self, from: Data(json.utf8))
            return .init(document: document, sources: sources, token: indexToken)
        }
        if flow == .vertical {
            if indexesFormulas { try await installFormulaIndex() }
            let document = try await VerticalPaginator.pages(
                in: session.webView, pageSize: pageSize, margins: margins, timeout: printTimeout)
            try session.checkRefreshOutput(document)
            if session.localHandler != nil { LocalResourceSchemeHandler.restoreFileLinks(in: document) }
            var result = Result(
                document: document, preparationResult: preparationResult, pageRules: pageRules,
                requiredFolderAccess: session.localHandler?.requiredFolderAccess)
            if indexesFormulas { result.diagramPass = try await formulaPass(document) }
            return result
        }
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
        if composesLatin {
            try await LaTeXFlowPaginator.installLatinLines(
                in: session.webView, diagnostics: collectsLatinLineDiagnostics, boxes: collectsLatinBoxDiagnostics,
                until: .now + timeout)
        }
        if collectsLatinLineDiagnostics && collectsLatinBoxDiagnostics {
            _ = try await session.webView.evaluateForPrinting(
                "globalThis.surimonoCollectJapaneseBoxes = true", until: .now + timeout)
        }
        var capturesLaTeXFlow = latexFlow
        // Page references, their reflow, and the final capture share one print budget.
        let layoutDeadline = ContinuousClock.now + printTimeout
        func remaining() -> Duration { ContinuousClock.now.duration(to: layoutDeadline) }
        func recordLines(final: Bool) async throws {
            guard collectsLatinLineDiagnostics else { return }
            let route = capturesLaTeXFlow ? "flow" : "native"
            latinLineRoute = route
            guard composesLatin || collectsLatinBoxDiagnostics else { return }
            let script = """
                const report = globalThis.surimonoLatinLast;
                const japanese = globalThis.surimonoJapaneseBoxes;
                if (!report && !japanese) return null;
                const summary = report ?? {qualifying:0, composed:0, fallbacks:0, paragraphs:[], hasLatinDiagnostics:false};
                return JSON.stringify({...summary, ...(japanese ? {japanese} : {}), route:'\(route)', final:\(final)});
                """
            guard let record = try await runPreparationScript(script, in: session.webView, timeout: timeout) else {
                if !composesLatin { return }
                throw PaginationError.printFailed
            }
            latinLinePasses.append(record)
            if final { latinLineDiagnostics = record }
        }
        func pageDataForPass(indexFormulas: Bool = false) async throws -> Data {
            guard capturesLaTeXFlow else {
                if composesLatin {
                    let width = (pageSize.width - margins.left - margins.right) * Self.printPixelsPerPoint
                    try await LaTeXFlowPaginator.prepareNativeLines(
                        in: session.webView, width: width, until: layoutDeadline)
                }
                if indexFormulas {
                    let width = (pageSize.width - margins.left - margins.right) * Self.printPixelsPerPoint
                    let media = session.webView.mediaType
                    session.webView.mediaType = "print"
                    defer { session.webView.mediaType = media }
                    _ = try await session.webView.evaluateForPrinting(
                        """
                        const root = document.documentElement;
                        const prior = root.style.cssText;
                        try {
                            root.style.width = width / (parseFloat(getComputedStyle(root).zoom) || 1) + 'px';
                            await document.fonts.ready;
                            surimonoFormulaIndex.native();
                        } finally { root.style.cssText = prior; }
                        """, arguments: ["width": width], until: layoutDeadline)
                }
                let data = try await session.printToPDF(
                    checkingBelowPaper: mayDrawBelowPaper, latexMarginInk: latexMarginInk,
                    deadline: latexPageNumbers == nil ? nil : layoutDeadline)
                if composesLatin {
                    _ = try await session.webView.evaluateForPrinting("surimonoRestoreLatin()", until: layoutDeadline)
                }
                return data
            }
            let pass = try await LaTeXFlowPaginator.paginate(
                in: session.webView, pageSize: pageSize, margins: margins, timeout: remaining(),
                scriptTimeout: timeout, evaluator: flowEvaluator, inspectPlan: inspectFlowPlan)
            // Keep the page references written by Quartz until the viewer opens these bytes.
            guard let data = pass.data else { throw PaginationError.emptyDocument }
            return data
        }
        func printHorizontal() async throws -> Result {
            if checksVerticalLaTeXInk || latexFlow {
                let width = (pageSize.width - margins.left - margins.right) * Self.printPixelsPerPoint
                // Failure of the ink measurement also needs a fresh single-column DOM.
                capturesLaTeXFlow = true
                let protrudes = try await LaTeXFlowPaginator.markVerticalInk(
                    in: session.webView, width: width, until: min(layoutDeadline, .now + timeout))
                capturesLaTeXFlow = latexFlow || protrudes
            }
            if checksVerticalLaTeXInk && !capturesLaTeXFlow && preparationScript != nil {
                _ = try await runPreparationScript(
                    "globalThis.surimonoFlowMarks?.(); delete globalThis.surimonoFlowMarks; delete globalThis.surimonoDefersMarks;",
                    in: session.webView, timeout: timeout)
            }
            let adjusted = try await Self.useHorizontalRootForOutput(in: session.webView, timeout: timeout)
            try Task.checkCancellation()
            var texPages: [LaTeXPageReferences.Page] = []
            var incompleteReferences = false
            if nativeLaTeXBreaks && !capturesLaTeXFlow {
                let media = session.webView.mediaType
                session.webView.mediaType = "print"
                defer { session.webView.mediaType = media }
                _ = try await runPreparationScript(
                    LaTeXPageReferences.coalesceNativeBreaks, in: session.webView, timeout: timeout)
            }
            if let latexPageNumbers {
                var measuringColumns = false
                do {
                    let token = UUID().uuidString
                    let webView = session.webView
                    let json = try await runPreparationScript(
                        LaTeXPageReferences.install(
                            token: token, runningMarks: latexPageNumbers.needsRunningMarks,
                            classPlain: latexPageNumbers.usesClassPlain,
                            nativePrint: !capturesLaTeXFlow),
                        in: webView, timeout: min(timeout, remaining()))
                    let installation = json.flatMap {
                        try? JSONDecoder().decode(LaTeXPageReferences.Installation.self, from: Data($0.utf8))
                    }
                    guard let installation else { throw PaginationError.printFailed }
                    incompleteReferences = installation.missing != 0
                    let targets = installation.targets
                    if !targets.isEmpty {
                        var previous: [String: String] = [:]
                        var previousScores: [LaTeXPageReferences.ExamScore] = []
                        var previousLocations: [Int: Int] = [:]
                        // Filling a reference can rewrap a line. Measure at most twice, always delivering a clean final PDF.
                        for _ in 0..<2 {
                            let locations: [Int: Int]
                            let count: Int
                            var blankPages: Set<Int> = []
                            if capturesLaTeXFlow {
                                measuringColumns = true
                                let pass = try await LaTeXFlowPaginator.paginate(
                                    in: webView, pageSize: pageSize,
                                    margins: margins, timeout: remaining(), referencesOnly: true,
                                    scriptTimeout: timeout, evaluator: flowEvaluator)
                                measuringColumns = false
                                locations = pass.locations
                                count = pass.pageCount
                                blankPages = pass.blankPages
                            } else {
                                let data = try await pageDataForPass()
                                guard let measured = PDFDocument(data: data) else {
                                    throw PaginationError.emptyDocument
                                }
                                locations = LaTeXPageReferences.locations(
                                    in: measured, token: token, count: targets.count)
                                count = measured.pageCount
                            }
                            try await recordLines(final: false)
                            incompleteReferences =
                                installation.missing != 0 || targets.indices.contains { locations[$0] == nil }
                            let map = LaTeXPageReferences.map(
                                latexPageNumbers, targets: targets,
                                locations: locations, pageCount: count, restartsAfterTitle: restartsAfterTitle,
                                blankPages: blankPages)
                            texPages = map.pages
                            if map.references == previous && map.examScores == previousScores
                                && locations == previousLocations
                            {
                                break
                            }
                            previousLocations = locations
                            previousScores = map.examScores
                            previous = map.references
                            let layout = try await runPreparationScript(
                                try LaTeXPageReferences.fill(
                                    previous, physicalPages: locations, examScores: previousScores), in: webView,
                                timeout: min(timeout, remaining()))
                            guard layout != nil else { throw PaginationError.printFailed }
                            if layout == "stable" && !capturesLaTeXFlow { break }
                        }
                    }
                    guard
                        try await runPreparationScript(
                            LaTeXPageReferences.removeProbes, in: webView, timeout: min(timeout, remaining()))
                            == "clean"
                    else { throw PaginationError.printFailed }
                } catch {
                    try Task.checkCancellation()
                    // Native pagination can still resolve the same anchors when only column measurement failed.
                    if error is CancellationError || measuringColumns { throw error }
                    throw LaTeXPageReferences.MeasurementFailed()
                }
            }
            if indexesFormulas { try await installFormulaIndex() }
            if let inspectPrintLayout {
                let webView = session.webView
                let media = webView.mediaType
                webView.mediaType = "print"
                await inspectPrintLayout(webView)
                webView.mediaType = media
            }
            let pageData = try await pageDataForPass(indexFormulas: indexesFormulas)
            try await recordLines(final: true)
            guard let document = PDFDocument(data: pageData) else { throw PaginationError.emptyDocument }
            try session.checkRefreshOutput(document)
            if session.localHandler != nil { LocalResourceSchemeHandler.restoreFileLinks(in: document) }
            var result = Result(
                document: document,
                preparationResult: preparationResult, pageRules: pageRules,
                requiredFolderAccess: session.localHandler?.requiredFolderAccess)
            // A preamble-only exam header can use final totals without any body destination to measure.
            if texPages.isEmpty, let state = latexPageNumbers, state.needsExamTotals || state.usesJournalFurniture {
                texPages =
                    LaTeXPageReferences.map(
                        state, targets: [], locations: [:], pageCount: document.pageCount,
                        restartsAfterTitle: false
                    ).pages
            }
            result.finishing.latexPages = texPages
            result.drawingBytes = pageData
            if adjusted { result.issues = [Self.verticalWritingIssue] }
            if incompleteReferences { result.issues.append(.unresolvedLaTeXPages) }
            if indexesFormulas {
                result.diagramPass = try await formulaPass(document)
            } else if collectsDiagrams {
                // Keep the finished PDF untouched even if measurement fails or a theme styles the extra anchors.
                do {
                    let token = UUID().uuidString
                    let width = (pageSize.width - margins.left - margins.right) * Self.printPixelsPerPoint
                    let webView = session.webView
                    let previousMedia = webView.mediaType
                    webView.mediaType = "print"
                    defer { webView.mediaType = previousMedia }
                    if let json = try await runPreparationScript(
                        DiagramGeometry.anchors(printWidth: width, token: token), in: webView, timeout: timeout),
                        let sources = try? JSONDecoder().decode([DiagramGeometry.Source].self, from: Data(json.utf8)),
                        !sources.isEmpty
                    {
                        let geometryData = try await pageDataForPass()
                        if let geometry = PDFDocument(data: geometryData), geometry.pageCount == document.pageCount {
                            result.diagramPass = .init(document: geometry, sources: sources, token: token)
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                }
            }
            return result
        }
        do {
            return try await printHorizontal()
        } catch {
            return try await retrySingleColumn(after: error, usedFlow: capturesLaTeXFlow)
        }

        func retrySingleColumn(after error: any Error, usedFlow: Bool) async throws -> Result {
            try Task.checkCancellation()
            if error is CancellationError || requiresProofLines || htmlComposition != nil { throw error }
            let lostReferences = error is LaTeXPageReferences.MeasurementFailed
            guard usedFlow || lostReferences else { throw error }
            // Discard this DOM even after a timeout: a late WebKit callback may still hold its measurement tree.
            session.requestClose()
            let cleanPreparation =
                lostReferences
                ? "{\n" + LaTeXPageReferences.prepareFields + "\n}\n" + (preparationScript ?? "") : preparationScript
            var fallback = try await paginateWithResult(
                source, pageSize: pageSize, margins: margins,
                allowsJavaScript: allowsJavaScript, printsBackgrounds: printsBackgrounds,
                preparationScript: cleanPreparation,
                readsPageRules: readsPageRules, drawsBackground: drawsBackground, rendersMermaid: rendersMermaid,
                rendersDiagrams: rendersDiagrams, collectsDiagrams: collectsDiagrams, indexesFormulas: indexesFormulas,
                latexPageNumbers: lostReferences ? nil : latexPageNumbers,
                restartsAfterTitle: restartsAfterTitle, composesLaTeXParagraphs: composesLatin,
                latexMarginInk: latexMarginInk, timeout: timeout)
            if lostReferences { fallback.issues.append(.unresolvedLaTeXPages) }
            if usedFlow {
                fallback.issues.append(
                    PrintIssue(
                        id: "latex-flow-fallback", kind: .latex,
                        detail: "LaTeX page layout could not be completed. Printed in one column with endnotes."))
            }
            return fallback
        }
    }

    private static let verticalWritingIssue = PrintIssue(id: "vertical-writing", kind: .verticalWriting, detail: "")

    private static func useHorizontalRootForOutput(in webView: WKWebView, timeout: Duration) async throws -> Bool {
        let adjusted = try await useHorizontalRoot(in: webView, timeout: timeout)
        // A root can be horizontal on screen and vertical only when AppKit starts drawing.
        let media = webView.mediaType
        webView.mediaType = "print"
        defer { webView.mediaType = media }
        let adjustedForPrint = try await useHorizontalRoot(in: webView, timeout: timeout)
        return adjusted || adjustedForPrint
    }

    /// WebKit's printing view crashes on a vertical root. Nested writing modes are safe.
    static func useHorizontalRoot(in webView: WKWebView, timeout: Duration = .seconds(15)) async throws -> Bool {
        let script = """
            const roots = [document.documentElement, document.body].filter(Boolean);
            const horizontal = element => {
              const style = getComputedStyle(element);
              return (style.writingMode || style.webkitWritingMode) === 'horizontal-tb';
            };
            if (roots.every(horizontal)) return false;
            for (const root of roots) root.style.setProperty('writing-mode', 'horizontal-tb', 'important');
            if (roots.every(horizontal)) return true;
            """
        guard
            let adjusted = try await webView.evaluateForPrinting(script, until: .now + timeout) as? Bool
        else { throw PaginationError.printFailed }
        return adjusted
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
        do {
            _ = try await webView.evaluateForPrinting(script, world: .defaultClient, until: .now + timeout)
        } catch {
            // Missing resources and WebKit evaluation errors have always allowed a best-effort print.
            try Task.checkCancellation()
        }
    }

    private func prepareMermaid(in webView: WKWebView, count: Int, timeout: Duration) async throws {
        do {
            // The document's own resources have loaded. Diagram-generated resources must never use the network.
            try await MermaidScript.preventResourceLoads(in: webView)
            guard let library = MermaidScript.library else {
                _ = try await runPreparationScript(MermaidScript.fallback, in: webView, timeout: timeout)
                return
            }
            mermaidLoadCount += 1
            guard
                try await runPreparationScript(
                    MermaidScript.loading(library), in: webView, timeout: timeout) == "function"
            else { throw PaginationError.timedOut }
            let budget = MermaidScript.budgetMilliseconds(count: count)
            _ = try await runPreparationScript(
                MermaidScript.rendering(budgetMilliseconds: budget), in: webView, timeout: .milliseconds(budget + 2000))
        } catch {
            try Task.checkCancellation()
            _ = try await runPreparationScript(MermaidScript.fallback, in: webView, timeout: timeout)
        }
    }

    private func runPreparationScript(_ script: String, in webView: WKWebView, timeout: Duration) async throws
        -> String?
    {
        do {
            return try await webView.evaluateForPrinting(script, until: .now + timeout) as? String
        } catch PaginationError.timedOut {
            throw PaginationError.timedOut
        } catch {
            // A failing cleanup script must not block printing.
            try Task.checkCancellation()
            return nil
        }
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
        var index = html.startIndex
        while let start = html[index...].firstIndex(of: "<") {
            let tail = html[start...]
            if tail.hasPrefix("<!--") {
                guard let end = tail.range(of: "-->") else { return nil }
                index = end.upperBound
                continue
            }
            let closing = tail.hasPrefix("</")
            let name = tail.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || "-:".contains($0) }
                .lowercased()
            if (!closing && name == "body") || (closing && name == "head") { return nil }
            var end = html.index(after: start)
            var quote: Character?
            while end < html.endIndex {
                let character = html[end]
                html.formIndex(after: &end)
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
            }
            index = end
            if closing { continue }
            if name == "base", let href = baseHref(in: String(html[start..<end])) { return href }
            if name == "script" || name == "style" {
                // Raw text can contain a literal '<body>' or '<base>'; resume at its closing tag.
                let closingTag = "</" + name
                while let next = html[index...].firstIndex(of: "<") {
                    let candidate = html[next...].prefix(closingTag.count)
                    index = candidate.endIndex
                    if candidate.lowercased() == closingTag,
                        let boundary = html[index...].first, boundary == ">" || boundary.isWhitespace
                    {
                        index = next
                        break
                    }
                    index = html.index(after: next)
                }
            }
        }
        return nil
    }

    private static func baseHref(in visible: String) -> String? {
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
    private let onPrintStart: (WKWebView) -> Void
    private let onPrintFinish: () -> Void
    private let onClose: () -> Void
    let localHandler: LocalResourceSchemeHandler?
    private var temporaryFiles: [URL] = []
    private var printCompletion: PrintCompletion?
    private var isPrinting = false
    private var closeRequested = false
    private var isClosed = false

    var navigationState: NavigationTracker.State { navigationTracker.state }
    /// Why the page's process ended, once it has.
    var terminationError: String? { navigationTracker.terminationError }
    func checkRefreshOutput(_ document: PDFDocument) throws {
        guard #unavailable(macOS 26), navigationTracker.stoppedRefreshCycle else { return }
        for index in 0..<document.pageCount {
            if document.page(at: index)?.string?.contains(where: { !$0.isWhitespace }) == true { return }
        }
        throw WebPaginator.PaginationError.loadFailed(URLError(.httpTooManyRedirects).localizedDescription)
    }
    var hasCommitted: Bool { navigationTracker.hasCommitted }

    /// Gives up on the resources still loading; the document counts as loaded with what has arrived.
    func stopLoadingResources() {
        navigationTracker.finishStopped()
        webView.stopLoading()
    }

    init(
        source: WebPaginator.Source, pageSize: CGSize, margins: WebPaginator.Margins, allowsJavaScript: Bool,
        printsBackgrounds: Bool,
        drawsBackground: Bool = true, printTimeout: Duration, onPrintStart: @escaping (WKWebView) -> Void,
        onPrintFinish: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.allowsJavaScript = allowsJavaScript
        self.printTimeout = printTimeout
        self.onPrintStart = onPrintStart
        self.onPrintFinish = onPrintFinish
        self.onClose = onClose
        if case .sandboxed(let html, let access, _) = source {
            localHandler = LocalResourceSchemeHandler(access: access, html: html)
        } else {
            localHandler = nil
        }
        let configuration = WKWebViewConfiguration()
        if case .html(_, let base?) = source, !base.isFileURL {
            configuration.websiteDataStore = .nonPersistent()
            navigationTracker.isDownloadedPage = true
        }
        if let localHandler {
            configuration.setURLSchemeHandler(localHandler, forURLScheme: LocalResourceSchemeHandler.scheme)
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        // Incremental rendering is not suppressed: WebKit then draws nothing until the load completes, so a page
        // whose pending resources were given up on would print blank.
        configuration.preferences.shouldPrintBackgrounds = printsBackgrounds
        configuration.setURLSchemeHandler(snapshotHandler, forURLScheme: SnapshotSchemeHandler.scheme)
        let printableWidth = max(pageSize.width - margins.left - margins.right, 72)
        let frame = CGRect(x: 0, y: 0, width: printableWidth, height: pageSize.height)
        webView = WKWebView(frame: frame, configuration: configuration)
        if !drawsBackground { WebPaginator.clearBackground?(webView) }
        // WebKit only produces non-blank print output for a view that lives in a window.
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        navigationTracker.keepsFirstDocument = true
        navigationTracker.followsOtherDocuments = WebPaginator.followsOtherDocuments(source)
        webView.navigationDelegate = navigationTracker
    }

    func load(_ source: WebPaginator.Source) throws {
        switch source {
        case .sandboxed(_, let access, _):
            webView.load(URLRequest(url: LocalResourceSchemeHandler.url(for: access.documentURL)))
        case .html(let html, let baseURL?) where baseURL.isFileURL && !allowsJavaScript:
            // loadHTMLString does not grant file read access, so images next to the document would not load.
            // Load a temporary copy instead. Reading is allowed broadly so that references such as ../images/
            // keep working, which is acceptable only because the page cannot run JavaScript to read and send
            // local files, and no other local file is loaded as a document (`generatedPageURL`).
            let url = temporaryURL(extension: "html")
            try Data(WebPaginator.injectingBase(baseURL, into: html).utf8).write(to: url)
            navigationTracker.generatedPageURL = url
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

    func loadForPrinting(
        _ source: WebPaginator.Source, timeout: Duration,
        expireAfterCommit: (@MainActor (WKWebView) async throws -> Void)?
    ) async throws -> Bool {
        try load(source)
        var expired = false
        do {
            try await WebPaginator.waitUntil(timeout: timeout) {
                navigationState != .loading || navigationTracker.terminationError != nil
                    || (expireAfterCommit != nil && hasCommitted)
            }
        } catch WebPaginator.PaginationError.timedOut {
            expired = true
        }
        if !expired, let expireAfterCommit, hasCommitted, navigationState == .loading,
            navigationTracker.terminationError == nil
        {
            try await expireAfterCommit(webView)
            expired = navigationState == .loading
        }
        if expired {
            // A never-loading resource may hold up a complete, printable document.
            guard hasCommitted else { throw WebPaginator.PaginationError.timedOut }
            let state =
                try await webView.evaluateForPrinting(
                    "return document.readyState", until: .now + min(timeout, .seconds(2))) as? String
            guard state == "complete" || state == "interactive" else { throw WebPaginator.PaginationError.timedOut }
            stopLoadingResources()
            return true
        }
        if let message = navigationTracker.terminationError { throw WebPaginator.PaginationError.loadFailed(message) }
        if case .failed(let message) = navigationState { throw WebPaginator.PaginationError.loadFailed(message) }
        return false
    }

    /// - Parameter checkingBelowPaper: Whether the document may draw below the paper, so that the pages are cut back
    ///   to the paper only after finding nothing there.
    func printToPDF(
        checkingBelowPaper: Bool, latexMarginInk: Bool = false, deadline: ContinuousClock.Instant? = nil
    ) async throws -> Data {
        let deadline = deadline ?? .now + printTimeout
        let outputURL = temporaryURL(extension: "pdf")
        let printInfo = NSPrintInfo()
        printInfo.paperSize = CGSize(width: pageSize.width, height: pageSize.height + Self.pageHeightAllowance)
        printInfo.topMargin = margins.top
        printInfo.leftMargin = margins.left
        // The allowance goes into the bottom margin, so a document laid out with these margins keeps its height.
        printInfo.bottomMargin = margins.bottom + Self.pageHeightAllowance
        printInfo.rightMargin = margins.right
        if latexMarginInk {
            // NSPrintOperation clips to the printable width before Quartz sees the page. Give the root
            // the horizontal white space instead, so a number outside its pre or a frame on the last
            // fractional pixel can still paint. The text keeps exactly the same physical measure.
            _ = try await webView.evaluateForPrinting(
                """
                if (globalThis.surimonoMarginInk) globalThis.surimonoMarginInk.remove();
                const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
                const style = document.createElement('style');
                style.textContent = `@media print { html { box-sizing: border-box !important;
                  padding-left: ${left / zoom}px !important; padding-right: ${right / zoom}px !important; } }`;
                document.head.append(style);
                globalThis.surimonoMarginInk = style;
                """,
                arguments: [
                    "left": margins.left * WebPaginator.printPixelsPerPoint,
                    "right": margins.right * WebPaginator.printPixelsPerPoint,
                ],
                until: deadline)
            printInfo.leftMargin = 0
            printInfo.rightMargin = 0
        }
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
        var printBounds = webView.bounds
        if latexMarginInk { printBounds.size.width = pageSize.width }
        operation.view?.frame = printBounds

        // The completion keeps this session alive (and the session keeps the completion) until printing ends.
        let completion = PrintCompletion { [self] in printDidFinish() }
        printCompletion = completion
        isPrinting = true
        #if DEBUG
            // Observe the hidden print window itself; the visible document can be on another display.
            if let state = ProcessInfo.processInfo.environment["SURIMONO_SNAPSHOT_STATE"],
                ProcessInfo.processInfo.arguments.contains("-SurimonoExportPath"), let screen = window.screen,
                let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            {
                let url = URL(fileURLWithPath: state).deletingLastPathComponent().appendingPathComponent(
                    "layout-screen.json")
                let metadata: [String: Any] = ["displayID": display, "backingScale": screen.backingScaleFactor]
                try? JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys).write(
                    to: url, options: .atomic)
            }
        #endif
        onPrintStart(webView)
        operation.runModal(
            for: window, delegate: completion,
            didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)

        while completion.result == nil {
            // Cancellation takes precedence over the deadline.
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw WebPaginator.PaginationError.timedOut }
            // A print of a page whose process has ended waits out the whole deadline (a minute or more) without this.
            if let message = navigationTracker.terminationError {
                throw WebPaginator.PaginationError.loadFailed(message)
            }
            // Task.sleep returns immediately once cancelled, which would spin the main thread and starve the
            // completion callback, so pause on the main queue instead.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { continuation.resume() }
            }
        }
        // The task may have been cancelled while the last pause was in flight.
        try Task.checkCancellation()
        // The process may have ended between the last check and the print's end; its pages would lack their text.
        if let message = navigationTracker.terminationError {
            throw WebPaginator.PaginationError.loadFailed(message)
        }
        guard completion.result == true else { throw WebPaginator.PaginationError.printFailed }
        if latexMarginInk {
            _ = try await webView.evaluateForPrinting(
                "globalThis.surimonoMarginInk.remove(); delete globalThis.surimonoMarginInk;",
                arguments: [:], until: deadline)
        }
        return try await Self.cutToPaper(at: outputURL, pageSize: pageSize, checkingBelowPaper: checkingBelowPaper)
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
    @concurrent private static func cutToPaper(at url: URL, pageSize: CGSize, checkingBelowPaper: Bool) async throws
        -> Data
    {
        guard let bytes = try? Data(contentsOf: url), let document = PDFDocument(data: bytes), document.pageCount > 0
        else { throw WebPaginator.PaginationError.emptyDocument }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if checkingBelowPaper, drawsBelowPaper(page, paperHeight: pageSize.height) { return bytes }
            let media = page.bounds(for: .mediaBox)
            let height = min(pageSize.height, media.height)
            let paper = CGRect(x: media.minX, y: media.maxY - height, width: media.width, height: height)
            page.setBounds(paper, for: .mediaBox)
            page.setBounds(paper, for: .cropBox)
        }
        guard let cut = document.dataRepresentation() else { throw WebPaginator.PaginationError.printFailed }
        return cut
    }

    /// Whether the page draws anything below the paper's height. The strip is rendered on white and any pixel that is
    /// not near-white counts, so text, rules, images and backgrounds all keep the page whole.
    nonisolated static func drawsBelowPaper(_ page: PDFPage, paperHeight: CGFloat) -> Bool {
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
    /// Why the web content process ended, set once when it does: nothing the session waits for can arrive any more,
    /// and a later navigation callback that sets `state` must not make the session look healthy again.
    private(set) var terminationError: String?
    /// The main document has started to arrive; before that the web view still shows its initial empty page.
    private(set) var hasCommitted = false
    private var isStopped = false
    private var activeNavigation: WKNavigation?
    /// Set for generated pages, which may read any local file so that references such as ../images/ work. Images and
    /// style sheets only draw what they are, but a document shows a file's content: `<iframe>`, `<object>`, `<embed>`
    /// or a `<meta http-equiv="refresh">` in the document's raw HTML could otherwise put an unopened file, such as a
    /// private key, onto the paper. Only this page itself is loaded as a document; no frame loads a local file.
    var generatedPageURL: URL?
    var isDownloadedPage = false
    /// Set for the paginator: the paper is the document as first loaded. A `<meta http-equiv="refresh">` in a page
    /// laid out from memory navigated it to a blank page, which then printed without its text and without an error.
    var keepsFirstDocument = false
    /// Set for a document opened from a file: it may go on to another document within its read access (an
    /// `index.html` that refreshes to `chapter.html`), as it always could. Reloading itself is still refused.
    var followsOtherDocuments = false
    private var allowedDownloadedPage = false
    private var firstLocalRequest: URL?
    private var followedPages = Set<String>()
    private(set) var stoppedRefreshCycle = false

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if isDownloadedPage || keepsFirstDocument, navigationAction.targetFrame?.isMainFrame != false,
            !staysInDocument(navigationAction, current: webView.url)
        {
            // The paper is the fetched response, even if a script or meta refresh tries to navigate elsewhere.
            guard navigationAction.targetFrame != nil else {
                decisionHandler(.cancel)
                return
            }
            if allowedDownloadedPage {
                let leaves =
                    followsOtherDocuments && !isDownloadedPage && navigationAction.navigationType != .reload
                    && !Self.isSameDocument(navigationAction.request.url, webView.url)
                guard leaves else {
                    decisionHandler(.cancel)
                    return
                }
            }
            // On Sequoia, two immediate cross-document refreshes can replace the DOM during printing.
            // Leave the current document in place on a return trip. Ordinary opens do not build a URL set.
            if #unavailable(macOS 26), followsOtherDocuments, let url = navigationAction.request.url {
                if let firstLocalRequest {
                    let destination = Self.page(url).page
                    if destination == Self.page(firstLocalRequest).page || !followedPages.insert(destination).inserted {
                        stoppedRefreshCycle = true
                        decisionHandler(.cancel)
                        return
                    }
                } else {
                    firstLocalRequest = url
                }
            }
            allowedDownloadedPage = true
        }
        decisionHandler(Self.allows(navigationAction, generatedPageURL: generatedPageURL) ? .allow : .cancel)
    }

    /// A jump to an anchor of the committed document: a GET that is not a form submission or reload, to the same
    /// page with another fragment. The paginator let it through before it kept the first document. A refresh to an
    /// anchor is reported as a reload and, in a page laid out from memory, loaded a blank page; a form posted to an
    /// anchor loads a new document.
    private func staysInDocument(_ action: WKNavigationAction, current: URL?) -> Bool {
        guard keepsFirstDocument, !isDownloadedPage, hasCommitted, action.targetFrame != nil else { return false }
        guard ![.reload, .formSubmitted, .formResubmitted].contains(action.navigationType),
            (action.request.httpMethod ?? "GET").uppercased() == "GET"
        else { return false }
        return Self.differsOnlyByFragment(action.request.url, from: current)
    }

    /// The URL without its fragment. A page laid out from memory is `about:blank`, whose fragment WebKit reports
    /// escaped (`about:blank%23b`).
    private static func page(_ url: URL) -> (page: String, fragment: Bool) {
        let string = url.absoluteString
        if let hash = string.firstIndex(of: "#") { return (String(string[..<hash]), true) }
        if url.scheme == "about", let escaped = string.range(of: "%23") {
            return (String(string[..<escaped.lowerBound]), true)
        }
        return (string, false)
    }

    /// Whether the two URLs name the same document, whatever their fragments.
    static func isSameDocument(_ url: URL?, _ current: URL?) -> Bool {
        guard let url, let current else { return url == current }
        return page(url).page == page(current).page
    }

    /// Whether `url` is `current` with another fragment: a navigation that does not load a document.
    static func differsOnlyByFragment(_ url: URL?, from current: URL?) -> Bool {
        guard let url, let current, url.absoluteString != current.absoluteString else { return false }
        return page(url).fragment && isSameDocument(url, current)
    }

    private static func allows(_ action: WKNavigationAction, generatedPageURL: URL?) -> Bool {
        guard let generatedPageURL else { return true }
        let url = action.request.url
        if action.targetFrame?.isMainFrame ?? true {
            return url?.absoluteURL.standardizedFileURL == generatedPageURL.absoluteURL.standardizedFileURL
        }
        return url?.isFileURL != true
    }

    /// Stopping reports the navigation as failed with a cancellation, which is not a failure of the document.
    func finishStopped() {
        isStopped = true
        state = .finished
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let message =
            terminationError
            ?? NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
            .localizedDescription
        terminationError = message
        state = .failed(message)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isStopped else { return }
        activeNavigation = navigation
        hasCommitted = false
        state = .loading
    }

    // A cancelled older navigation can fail after the replacement has committed.
    private func accepts(_ navigation: WKNavigation?) -> Bool {
        !isStopped && (activeNavigation == nil || activeNavigation === navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard accepts(navigation) else { return }
        hasCommitted = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard accepts(navigation) else { return }
        state = .finished
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard accepts(navigation) else { return }
        state = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        guard accepts(navigation) else { return }
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
