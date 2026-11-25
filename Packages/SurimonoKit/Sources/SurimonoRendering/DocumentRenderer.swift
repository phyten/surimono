import Foundation
import PDFKit
import SurimonoCore

public struct DocumentSource: Equatable, Sendable {
    public let data: Data
    public let fileURL: URL?
    /// The file name a document came with when that is not the name of `fileURL`: a file Shortcuts handed over in
    /// memory, or under a temporary URL with a name of its own. What a file's name tells (a source file's
    /// language) is told from this first. Two documents of the same bytes under different names are different.
    public private(set) var name: String?
    public private(set) var htmlBaseURL: URL?
    public let format: DocumentFormat
    public let images: [Image]?
    public let children: [DocumentSource]?
    public private(set) var contentHash: ContentHash?
    public var allowedResourceFolders: [URL] = []
    /// The HTML is a copy of a live page's current state rather than the file's bytes; its own scripts already ran.
    public let isLiveSnapshot: Bool
    fileprivate var usesLoadedHTML = false

    /// One image of a bundle. Its bytes are read only while its page is drawn and released afterwards, so a large
    /// bundle such as a ZIP of photos is never held in memory at once. Images compare by file and content hash.
    public struct Image: Equatable, Sendable {
        /// The bytes read now are not the content the image was identified by, for example because the file was
        /// edited after it was hashed.
        public struct ContentChanged: Error, Equatable {
            public let fileURL: URL
        }

        public let fileURL: URL
        public let contentHash: ContentHash
        private let load: @Sendable () throws -> Data

        public init(fileURL: URL, contentHash: ContentHash, load: @escaping @Sendable () throws -> Data) {
            self.fileURL = fileURL
            self.contentHash = contentHash
            self.load = load
        }

        /// An image whose bytes are already in memory.
        public init(data: Data, fileURL: URL) {
            self.init(fileURL: fileURL, contentHash: .of(data), load: { data })
        }

        /// Reads the bytes and checks them against the content hash, so a page is never drawn from other content.
        public func data() throws -> Data {
            let data = try load()
            guard ContentHash.of(data) == contentHash else { throw ContentChanged(fileURL: fileURL) }
            return data
        }

        public static func == (lhs: Image, rhs: Image) -> Bool {
            lhs.fileURL == rhs.fileURL && lhs.contentHash == rhs.contentHash
        }
    }

    public static func binder(_ children: [DocumentSource]) -> Self {
        Self(
            data: Data(), fileURL: nil, format: .pdf, isLiveSnapshot: false,
            children: children.map {
                var child = $0.hashed()
                child.usesLoadedHTML = child.format == .html
                return child
            })
    }

    /// Binder loading computes this off the main actor once; ordinary single-document renders keep their existing
    /// byte comparison and do not hash a large PDF on every settings change.
    public func hashed() -> Self {
        var source = self
        if source.contentHash == nil { source.contentHash = .of(data) }
        return source
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        let sameContent: Bool
        if let left = lhs.contentHash, let right = rhs.contentHash {
            sameContent = left == right
        } else {
            sameContent = lhs.data == rhs.data
        }
        return sameContent && lhs.fileURL == rhs.fileURL && lhs.name == rhs.name && lhs.format == rhs.format
            && lhs.images == rhs.images && lhs.children == rhs.children
            && lhs.allowedResourceFolders == rhs.allowedResourceFolders && lhs.isLiveSnapshot == rhs.isLiveSnapshot
            && lhs.usesLoadedHTML == rhs.usesLoadedHTML && lhs.htmlBaseURL == rhs.htmlBaseURL
    }

    public static func images(_ images: [Image]) -> Self { Self(images: images) }

    /// The current state of a live HTML page, laid out against the directory of `fileURL` without running scripts.
    public static func liveSnapshot(_ html: String, of fileURL: URL?) -> Self {
        Self(data: Data(html.utf8), fileURL: fileURL, format: .html, isLiveSnapshot: true)
    }

    private init(images: [Image]) {
        data = Data()
        fileURL = nil
        format = .image
        self.images = images
        children = nil
        contentHash = .imageSet(images.map(\.contentHash))
        isLiveSnapshot = false
    }

    /// The same document under the file name it came with.
    public func named(_ name: String?) -> DocumentSource {
        var source = self
        source.name = name
        return source
    }

    public init(data: Data, fileURL: URL? = nil, format: DocumentFormat, htmlBaseURL: URL? = nil) {
        self.init(data: data, fileURL: fileURL, format: format, isLiveSnapshot: false)
        if format == .html, let htmlBaseURL { self.htmlBaseURL = URLDocument.address(htmlBaseURL.absoluteString) }
    }

    private init(
        data: Data, fileURL: URL?, format: DocumentFormat, isLiveSnapshot: Bool, children: [DocumentSource]? = nil
    ) {
        self.data = data
        self.children = children
        contentHash = nil
        self.fileURL = fileURL
        self.format = format
        images = nil
        self.isLiveSnapshot = isLiveSnapshot
    }

    /// Whether the page's own JavaScript runs while it is laid out.
    func allowsJavaScript(_ settings: RenderSettings) -> Bool {
        format == .html && !isLiveSnapshot && settings.allowsPageJavaScript
    }
}

public struct RenderSettings: Equatable, Sendable {
    public var paperOrientation: PaperOrientation
    public var layout: PrintLayout
    public var theme: PrintTheme
    public var typeface: Typeface
    public var textScale: Double
    var readingTrim: CGSize?
    var logicalPageSize: CGSize { readingTrim ?? layout.logicalPageSize(options: options) }

    public func forReadingLaTeX(_ info: LaTeXDocumentClassInfo) -> Self {
        guard let size = info.declaredPaperSize else { return self }
        var reading = self
        reading.layout = (PrintLayout.readingLaTeXLayout(for: size) ?? .a4Single).oriented(size.width > size.height)
        reading.readingTrim = nil
        if abs(reading.layout.logicalPageSize.width - size.width) >= 0.1
            || abs(reading.layout.logicalPageSize.height - size.height) >= 0.1
        {
            reading.readingTrim = size
        }
        if paperOrientation != .auto || theme.formats != [.latex]
            || (size.width > size.height) != (info.pageBox.paperWidth > info.pageBox.paperHeight)
        {
            reading.paperOrientation = size.width > size.height ? .landscape : .portrait
        }
        return reading
    }

    public var orgReading = OrgReadingSettings()
    public var latexComposition = LaTeXComposition.document
    /// The colors and blocks of the document's code; the print theme's own by default.
    public var code = CodeStyle()
    public var preset: HTMLCleanupPreset
    public var options: PrintOptions
    var latexFooter: PageFurniture.LaTeXFooter?
    public var allowsJavaScriptInHTML: Bool
    /// Live HTML and paper must enforce the same combination of user and preset policy.
    public var allowsPageJavaScript: Bool { allowsJavaScriptInHTML && !preset.disablesJavaScript }
    public var smartRemoval: SmartRemovalRequest?
    /// HTML: open every `<details>` of the copy being laid out.
    public var opensDetails: Bool
    /// HTML that is a slide deck: print its slides one to a page, landscape in Auto.
    public var slides: SlidePrintRequest?
    public var binderStartsOnFront = false
    var indexesFormulas = false
    public var markdownChanges: [MarkdownMarkRequest]
    public var changeBackgroundHex = ChangeMark.defaultBackgroundHex
    public var changeTextHex: String?
    /// Where a text breaks and how it shows its table of contents.
    public var finish = PrintFinish()
    /// Pages to write on among the document's own; only a document of its own takes them, not a binder.
    public var notes = NotePages()
    /// The name the header and footer call the document by; without one, the name of its file.
    public var documentName: String?
    /// The language of what the app itself puts on the page, such as the title of the contents.
    public var pageLanguage = "ja"
    /// The pages that go on the sheets. The logical pages are laid out the same whatever it is.
    public var pageRange = PageRange.all

    func textWidthPoints(in layout: PrintLayout) -> Double {
        let margins = layout.logicalMargins(options: options)
        // The graphics reader receives PDF points; PrintOptions stores millimetres.
        return (readingTrim ?? layout.logicalPageSize(options: options)).width - (margins.left + margins.right) * 72
            / 25.4
    }

    var usesPerPageOrientation: Bool {
        layout.kind == .normal && layout.duplex == .none && paperOrientation == .auto
    }

    var activeNotes: NotePages? { notes.isEnabled && notes.applies(to: layout) ? notes : nil }

    /// Note pages move the pages to other sides, so the margins are then turned round after the notes went in.
    var mirrorsLaidOutPages: Bool { layout.mirrorsMargins(options: options) && activeNotes == nil }

    public init(
        layout: PrintLayout, theme: PrintTheme, preset: HTMLCleanupPreset,
        options: PrintOptions? = nil, allowsJavaScriptInHTML: Bool = false,
        smartRemoval: SmartRemovalRequest? = nil, textScale: Double = 1, typeface: Typeface = .style,
        paperOrientation: PaperOrientation = .auto,
        opensDetails: Bool = false, slides: SlidePrintRequest? = nil, markdownChanges: [MarkdownMarkRequest] = []
    ) {
        self.markdownChanges = markdownChanges
        self.opensDetails = opensDetails
        self.slides = slides
        self.layout = layout
        self.paperOrientation = paperOrientation
        self.theme = theme
        self.typeface = typeface
        self.textScale = textScale
        self.preset = preset
        self.options = options ?? PrintOptions().defaults(for: theme.formats == [.latex] ? .latex : nil)
        self.allowsJavaScriptInHTML = allowsJavaScriptInHTML
        self.smartRemoval = smartRemoval
    }
}

public struct PaginationRequest: Sendable {
    public let source: WebPaginator.Source
    public let pageSize: CGSize
    public let margins: WebPaginator.Margins
    public let allowsJavaScript: Bool
    public let preparationScript: String?
    /// Whether the result should carry the document's `@page` rules.
    public let readsPageRules: Bool
    /// Whether a page without a background of its own is laid on white; false leaves it clear, for a paper laid under
    /// it (`WebPaginator.drawsClearPages`).
    public var drawsBackground = true
    public var rendersMermaid = false
    public var rendersDiagrams = false
    public var latexPageNumbers: LaTeXPageNumbers?
    public var restartsAfterTitle = false
    public var collectsDiagrams = false
    var indexesFormulas = false
    public var composesLaTeXParagraphs = false
    public var latexFlow = false
    public var latexMarginInk = false
    public var checksVerticalLaTeXInk = false
    var verticalBooklet = false
    var verticalTextScale: Double = 1
    public var flow = PrintFlow.horizontal
}

extension WebPaginator {
    func paginate(_ request: PaginationRequest) async throws -> Result {
        try await paginateWithResult(
            request.source, pageSize: request.pageSize, margins: request.margins,
            allowsJavaScript: request.allowsJavaScript, preparationScript: request.preparationScript,
            readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
            rendersMermaid: request.rendersMermaid, rendersDiagrams: request.rendersDiagrams,
            collectsDiagrams: request.collectsDiagrams, indexesFormulas: request.indexesFormulas,
            latexPageNumbers: request.latexPageNumbers,
            restartsAfterTitle: request.restartsAfterTitle,
            composesLaTeXParagraphs: request.composesLaTeXParagraphs,
            latexFlow: request.latexFlow,
            latexMarginInk: request.latexMarginInk, checksVerticalLaTeXInk: request.checksVerticalLaTeXInk,
            verticalBooklet: request.verticalBooklet, verticalTextScale: request.verticalTextScale, flow: request.flow)
    }
}

/// What the renderer adds to the pages of a text and what it reads from the text on the way.
struct FinishedPages {
    var sourceText: String?
    var latexPages: [LaTeXPageReferences.Page] = []
    var facts: DocumentFacts?
    var contentsPageCount = 0
    var blankPages: Set<Int> = []
    /// Where the note pages go, for pages laid out knowing about them.
    var plan: FinishedPagePlan?
    var notePages: [Int] = []
    /// Where the pages of the text went among the added ones; nil when nothing was added. With the text below, it lets
    /// the chapter of each page be found only when a header or footer asks for it.
    var pagePlan: FinishedPagePlan?
    var bodyHTML: String?
    var showsSourceContents = false
}

/// The logical pages of a render, ready to show before the printed sheets are composed.
@MainActor
public struct PreparedRender {
    /// Distinguishes this render from every other one of the same renderer; its `RenderResult` carries the same id.
    public let id: Int
    // Content orientation is retained separately because 2-up reverses the sheet orientation.
    public let resolvedOrientation: PaperOrientation
    public let layout: PrintLayout
    /// Shared with later renders whose logical pages are the same, so treat it as read-only.
    public let logicalDocument: PDFDocument
    /// The pages the view mode shows: the logical pages, except that an image's page leaves out the paper the image's
    /// shape does not fill. Shared like `logicalDocument`.
    public let viewDocument: PDFDocument
    public let plan: ImpositionPlan
    public let summary: PrintSummary
    public let requiredFolderAccess: URL?
    public let unreadableImageURLs: [URL]
    public let smartRemovalCandidates: [SmartRemovalCandidate]
    public let issues: [PrintIssue]
    public let changeMarks: [ChangeMark]
    public var diagrams: [RenderedDiagram] = []
    public let sourceLines: [Int: SourceLineLocation]
    public let sourceLineCount: Int
    public var formulaIndex: PaperFormulaIndex?
    public var unreadableDocumentURLs: [URL] = []
    public var binderDocuments: [URL: PDFDocument] = [:]
    public var binderPageStarts: [URL: Int] = [:]
    /// What the text says about itself, for a format that prints with a theme.
    public var facts: DocumentFacts?
    /// What was added to the text's pages.
    public var addedContentsPages = 0
    /// The logical pages that were added as blanks.
    public var blankPages: Set<Int> = []
    /// The logical pages that are note pages.
    public var notePages: [Int] = []
    /// The logical pages on the sheets, as `RenderSettings.pageRange` selects them from these pages.
    public var pageSelection = PageRange.Selection.everything
    /// How the logical pages took their mirrored margins, for showing a range of them as they print.
    public var laidOutSides: PDFComposer.LaidOutSides { sheetKey.sides }
    /// The header and footer the sheets draw on the pages of `viewDocument`, by page, for the view mode to draw on
    /// its paper too.
    public var viewFurniture: [Int: FurniturePlacement] = [:]
    /// The header and footer these pages were finished with.
    public var furniture: PageFurniture { options.furniture }
    /// The day their header and footer show, as written on them; empty without one.
    public var furnitureDate: String { sheetKey.furniture.date }
    var sourceBytes: Data?
    let sheetKey: SheetKey
    public let options: PrintOptions
}

/// What the composed sheets depend on: the logical pages they were made from and the settings of the imposition.
struct SheetKey: Equatable {
    let logicalID: Int
    let layout: PrintLayout
    let options: PrintOptions
    let orientsEachPage: Bool
    let furniture: PageFurniture.Context
    /// The logical pages on the sheets; nil for all of them.
    var pages: [Int]?
    var sides = PDFComposer.LaidOutSides()
}

@MainActor
public struct RenderResult {
    public let id: Int
    // Content orientation is retained separately because 2-up reverses the sheet orientation.
    public let resolvedOrientation: PaperOrientation
    // The uniform-layout fallback; mixed output must use sheetOrientations instead.
    public var sheetOrientation: PaperOrientation {
        layout.sheetSize.width > layout.sheetSize.height ? .landscape : .portrait
    }
    /// Indexed by sheetDocument page (a printed side), including any imposed blank back.
    public let sheetOrientations: [PaperOrientation]
    public var hasMixedSheetOrientations: Bool { Set(sheetOrientations).count > 1 }
    public let layout: PrintLayout
    public let logicalDocument: PDFDocument
    /// Shared with later renders of the same sheets, so treat it as read-only.
    public let sheetDocument: PDFDocument
    public let plan: ImpositionPlan
    public let summary: PrintSummary
    public let requiredFolderAccess: URL?
    public let unreadableImageURLs: [URL]
    public let unreadableDocumentURLs: [URL]
    public let smartRemovalCandidates: [SmartRemovalCandidate]
    public let issues: [PrintIssue]
    public let changeMarks: [ChangeMark]
    public let diagrams: [RenderedDiagram]
    public let facts: DocumentFacts?
    public let addedContentsPages: Int
    public let blankPages: Set<Int>
    public let notePages: [Int]
    public var addedNotePages: Int { notePages.count }
    public let pageSelection: PageRange.Selection
    public let laidOutSides: PDFComposer.LaidOutSides

    init(_ prepared: PreparedRender, sheet: PDFDocument, sheetOrientations: [PaperOrientation]) {
        id = prepared.id
        resolvedOrientation = prepared.resolvedOrientation
        layout = prepared.layout
        logicalDocument = prepared.logicalDocument
        sheetDocument = sheet
        self.sheetOrientations = sheetOrientations
        plan = prepared.plan
        summary = prepared.summary
        requiredFolderAccess = prepared.requiredFolderAccess
        unreadableImageURLs = prepared.unreadableImageURLs
        unreadableDocumentURLs = prepared.unreadableDocumentURLs
        smartRemovalCandidates = prepared.smartRemovalCandidates
        issues = prepared.issues
        changeMarks = prepared.changeMarks
        diagrams = prepared.diagrams
        facts = prepared.facts
        addedContentsPages = prepared.addedContentsPages
        blankPages = prepared.blankPages
        notePages = prepared.notePages
        pageSelection = prepared.pageSelection
        laidOutSides = prepared.laidOutSides
    }
}

/// Keep one renderer per open document and cancel the previous caller Task before starting a new render.
@MainActor
public final class DocumentRenderer {
    public enum RenderingError: Error, Equatable {
        case noReadableImages([URL])
        case noReadableDocuments([URL])
        /// An image's content no longer matches the hash it was identified by; hash the images again and retry.
        case imageChanged(URL)
        case unsupportedFormat
        case tooLarge(bytes: Int)
        case textDecodingFailed
        case invalidPDF
        case encryptedPDF
        case invalidMargins
        /// The note pages' lines and margins do not fit on the page.
        case invalidNotePage
        case pagination(WebPaginator.PaginationError)
        case paginationFailed
        case image(ImagePageRenderer.RenderingError)
        case composition(PDFComposer.CompositionError)
    }

    public typealias Paginate = @MainActor (PaginationRequest) async throws -> PDFDocument
    public typealias PaginateWithResult = @MainActor (PaginationRequest) async throws -> WebPaginator.Result

    public private(set) var logicalRenderCount = 0
    private let paginate: PaginateWithResult
    private let isSandboxed: () -> Bool
    public private(set) var sheetCompositionCount = 0
    /// Runs before each composition that the sheet cache cannot serve. Tests hold or fail a composition with it to
    /// pin what the app shows between the logical pages and their sheets.
    public var willComposeSheet: (@MainActor () async throws -> Void)?
    /// The day the header and footer print as today.
    public var now: @MainActor () -> Date = { Date() }
    private var childRenderers: [String: DocumentRenderer] = [:]
    public private(set) var binderChildRenderCount = 0
    private var cache: (key: CacheKey, logical: Logical)?
    /// The most recent composed sheets, so that going back to a recent layout or option does not compose again.
    private var sheets: [(key: SheetKey, document: PDFDocument, orientations: [PaperOrientation])] = []
    private static let sheetCacheLimit = 2
    private var generation = 0
    private var logicalSerial = 0
    private var sourcePageSizes: (source: DocumentSource, sizes: [CGSize])?
    /// The orientation the `@page` rules of an HTML source ask for, known once the source has been laid out.
    private var composedFragment: (source: DocumentSource, choice: LaTeXComposition, width: Double, input: ThemedInput)?
    var cachedLaTeXInfo: (source: DocumentSource, infos: [LaTeXComposition: LaTeXDocumentClassInfo])?
    private var sourcePageRule: (source: DocumentSource, orientation: PaperOrientation?)?

    /// The logical pages of a cache entry. The document is handed out as is, so that a view showing it keeps it.
    private final class Logical {
        let id: Int
        let document: PDFDocument
        let viewDocument: PDFDocument
        var requiredFolderAccess: URL?
        let unreadable: [URL]
        let candidates: [SmartRemovalCandidate]
        var unreadableDocuments: [URL] = []
        var binderDocuments: [URL: PDFDocument] = [:]
        var binderPageStarts: [URL: Int] = [:]
        var binderPageSizes: [CGSize] = []
        var issues: [PrintIssue] = []
        var changeMarks: [ChangeMark] = []
        var sourceLines: (locations: [Int: SourceLineLocation], lastNumber: Int) = ([:], 0)
        var diagrams: [RenderedDiagram] = []
        var markRequests: [MarkdownMarkRequest] = []
        var hasFormulas = false
        var formulaIndex: PaperFormulaIndex?
        var hasInkStencil = false
        var finishing = FinishedPages()
        /// Immutable drawing bytes when the pages already have a serialized representation.
        var composingSource: Data?
        /// These pages with note pages among them. Note pages are drawn without WebKit, so changing their lines does
        /// not lay the document out again.
        var noted: (key: NotedKey, logical: Logical)?

        init(
            id: Int, document: PDFDocument, viewDocument: PDFDocument, unreadable: [URL],
            candidates: [SmartRemovalCandidate]
        ) {
            self.id = id
            self.document = document
            self.viewDocument = viewDocument
            self.unreadable = unreadable
            self.candidates = candidates
        }
    }

    private struct NotedKey: Equatable {
        let notes: NotePages
        let layoutKind: LayoutKind
        let pageSize: CGSize
        let mirrorShift: CGFloat
        let rightBound: Bool
    }

    private struct CacheKey: Equatable {
        let source: DocumentSource
        let pageSize: CGSize
        let verticalBooklet: Bool
        let mixesImagePages: Bool
        let theme: PrintTheme?
        let typeface: Typeface?
        let textScale: Double?
        let code: CodeStyle?
        let preset: HTMLCleanupPreset?
        let margins: PageMargins
        let orgReading: OrgReadingSettings?
        let latexComposition: LaTeXComposition
        let usesDocumentWidth: Bool
        let allowsJavaScript: Bool
        let smartRemoval: SmartRemovalRequest?
        let opensDetails: Bool
        let slides: SlidePrintRequest?
        let binderStartsOnFront: Bool
        let binderOrientation: PaperOrientation?
        let binderLayout: PrintLayout?
        let finish: PrintFinish?
        let usesRightPages: Bool
        let mirrorsMargins: Bool
        let rightBound: Bool
        let contentsLanguage: String?
        let hasNotes: Bool
        /// A text numbers its contents and places its blanks knowing where the notes go.
        let textNotes: FinishedPagePlan.Notes?
    }

    public init(isSandboxed: @escaping () -> Bool = { SandboxEnvironment.isSandboxed }, paginate: Paginate? = nil) {
        self.isSandboxed = isSandboxed
        if let paginate {
            self.paginate = { request in WebPaginator.Result(document: try await paginate(request)) }
        } else {
            self.paginate = { request in try await WebPaginator().paginate(request) }
        }
    }

    public init(
        isSandboxed: @escaping () -> Bool = { SandboxEnvironment.isSandboxed },
        paginateWithResult: @escaping PaginateWithResult
    ) {
        self.isSandboxed = isSandboxed
        self.paginate = paginateWithResult
    }

    /// Invalidate after external images, fonts, or an HTML file change without a change to source.data.
    public func clearCache() {
        generation += 1
        cache = nil
        childRenderers.removeAll()
        sheets = []
        sourcePageSizes = nil
        sourcePageRule = nil
        cachedLaTeXInfo = nil
        composedFragment = nil
    }

    /// Prepares the logical pages and composes the printed sheets.
    public func render(_ source: DocumentSource, settings: RenderSettings) async throws -> RenderResult {
        try await composeSheet(for: try await prepare(source, settings: settings))
    }

    /// Prepares the logical pages only. The screen can show them while `composeSheet(for:)` imposes them on paper.
    public func prepare(
        _ source: DocumentSource, settings: RenderSettings,
        onReadingPreview: (@MainActor (ReadingPreview) -> Void)? = nil
    ) async throws -> PreparedRender {
        let interval = renderingSignposter.beginInterval(
            "prepare", id: renderingSignposter.makeSignpostID(), "format=\(source.format.rawValue, privacy: .public)")
        var pageCount = 0
        defer { renderingSignposter.endInterval("prepare", interval, "pages=\(pageCount)") }
        let output = try await prepareOnce(source, settings: settings, onReadingPreview: onReadingPreview)
        // HTML in Auto turns with its `@page` rules, which are known only once it has been laid out. A document that
        // asks for landscape is laid out again; the common upright one costs nothing more.
        if source.format == .html, settings.paperOrientation == .auto, settings.layout.kind != .booklet,
            settings.slides == nil, let rule = sourcePageRule, rule.source == source,
            (rule.orientation == .landscape) != (output.resolvedOrientation == .landscape)
        {
            let revised = try await prepareOnce(source, settings: settings)
            pageCount = revised.logicalDocument.pageCount
            return revised
        }
        pageCount = output.logicalDocument.pageCount
        return output
    }

    /// Composes the printed sheets of a prepared render, reusing the sheets of a recent render with the same logical
    /// pages and imposition settings.
    public func composeSheet(for prepared: PreparedRender, rotatesBackSides: Bool? = nil) async throws -> RenderResult {
        let interval = renderingSignposter.beginInterval(
            "composeSheet", id: renderingSignposter.makeSignpostID(),
            "pages=\(prepared.logicalDocument.pageCount)")
        defer { renderingSignposter.endInterval("composeSheet", interval) }
        // Printer calibration depends on the orientation resolved by prepare, without changing the logical pages.
        var options = prepared.options
        if let rotatesBackSides { options.rotatesBackSides = rotatesBackSides }
        let key = SheetKey(
            logicalID: prepared.sheetKey.logicalID, layout: prepared.layout, options: options,
            orientsEachPage: prepared.sheetKey.orientsEachPage, furniture: prepared.sheetKey.furniture,
            pages: prepared.sheetKey.pages, sides: prepared.sheetKey.sides)
        try Task.checkCancellation()
        if let index = sheets.firstIndex(where: { $0.key == key }) {
            let entry = sheets.remove(at: index)
            sheets.append(entry)
            return RenderResult(prepared, sheet: entry.document, sheetOrientations: entry.orientations)
        }
        do {
            try await willComposeSheet?()
            let source = PDFComposer.Source(prepared.logicalDocument, bytes: prepared.sourceBytes)
            let drawn = try await PDFComposer().compose(
                source, layout: prepared.layout, options: options,
                orientsEachPage: key.orientsEachPage, furniture: key.furniture, pages: key.pages, sides: key.sides)
            try Task.checkCancellation()
            guard let sheet = PDFDocument(data: drawn.data) else { throw RenderingError.invalidPDF }
            let orientations = drawn.orientations
            sheetCompositionCount += 1
            sheets.append((key, sheet, orientations))
            if sheets.count > Self.sheetCacheLimit { sheets.removeFirst(sheets.count - Self.sheetCacheLimit) }
            return RenderResult(prepared, sheet: sheet, sheetOrientations: orientations)
        } catch {
            throw Self.renderingError(error)
        }
    }

    private static func renderingError(_ error: any Error) -> any Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        switch error {
        case let error as RenderingError: return error
        case NotePageDrawing.DrawingError.invalidStyle, NotePageDrawing.DrawingError.invalidGeometry:
            return RenderingError.invalidNotePage
        case let error as WebPaginator.PaginationError: return RenderingError.pagination(error)
        case let error as ImagePageRenderer.RenderingError: return RenderingError.image(error)
        case let error as PDFComposer.CompositionError: return RenderingError.composition(error)
        // Says what is wrong with the file; "could not be paginated" would send the reader to reload it.
        case let error as DocxError: return error
        default: return RenderingError.paginationFailed
        }
    }

    /// Only the reading surface receives these pages. Output APIs require a completed PreparedRender.
    public struct ReadingPreview {
        public let document: PDFDocument
        public let layout: PrintLayout
        public let options: PrintOptions
        public let furniture: [Int: FurniturePlacement]
    }

    private func prepareOnce(
        _ source: DocumentSource, settings: RenderSettings, suppliedInput: ThemedInput? = nil,
        onReadingPreview: (@MainActor (ReadingPreview) -> Void)? = nil
    ) async throws -> PreparedRender {
        try Task.checkCancellation()
        generation += 1
        let currentGeneration = generation
        do {
            let requestedSettings = settings
            var settings = settings
            if source.children != nil || source.format != .latex || settings.theme.formats != [.latex] {
                settings.latexComposition = .document
            }
            if source.children != nil { settings.notes = NotePages() }
            var landscape: Bool
            if source.children != nil {
                landscape = settings.paperOrientation == .landscape && settings.layout.kind != .booklet
            } else if settings.layout.kind == .booklet {
                landscape = false
            } else if settings.paperOrientation == .auto, source.format == .html, let slides = settings.slides {
                // A slide prints best on paper of its own shape, whatever the deck's `@page` says.
                landscape = slides.slideSize.width > slides.slideSize.height
            } else if settings.paperOrientation == .auto, source.format == .latex, settings.theme.formats == [.latex] {
                let box = latexClassInfo(for: source).pageBox
                landscape = box.paperWidth > box.paperHeight
            } else if settings.paperOrientation == .auto {
                landscape = try await automaticLandscape(source)
            } else {
                landscape = settings.paperOrientation == .landscape
            }
            settings.layout = settings.layout.oriented(landscape)
            var input = suppliedInput
            if settings.latexComposition != .document {
                // Resolve body column switches before fitting margins, and reuse that conversion for pagination.
                var candidate = settings
                candidate.applyLaTeXPage(latexClassInfo(for: source, composition: settings.latexComposition))
                let width = candidate.textWidthPoints(in: candidate.layout)
                if let cached = composedFragment, cached.source == source, cached.choice == settings.latexComposition,
                    cached.width == width
                {
                    input = cached.input
                } else {
                    let read = try await Self.readThemedInput(
                        source, settings: candidate, access: resourceAccess(for: source))
                    try Task.checkCancellation()
                    if generation == currentGeneration {
                        composedFragment = (source, settings.latexComposition, width, read)
                    }
                    input = read
                }
                settings.latexComposition = input?.fragment.latexClass?.composition ?? .document
                if settings.latexComposition == .document { input = nil }
            }
            if source.format == .latex, source.children == nil,
                settings.latexComposition != .document
                    || settings.options.latexMargins?.applies(to: settings.theme) == true
                    || settings.options.latexFurniture?.applies(to: settings.theme) == true
            {
                settings.applyLaTeXPage(latexClassInfo(for: source, composition: settings.latexComposition))
            }
            let slideSize =
                source.format == .latex && source.children == nil ? latexClassInfo(for: source).beamerPageSize : nil
            if let slideSize { settings.readingTrim = slideSize }
            let pageSize = settings.logicalPageSize
            let margins =
                slideSize == nil ? settings.layout.logicalMargins(options: settings.options) : PageMargins.zero
            guard settings.options.margins.isValid,
                PDFDrawing.validGeometry(pageSize: pageSize, margins: WebPaginator.Margins(margins))
            else {
                throw RenderingError.invalidMargins
            }
            let isThemed = source.children == nil && source.format.usesPrintTheme
            let isPlainPDF = source.format == .pdf && source.children == nil
            let key = CacheKey(
                source: source, pageSize: isPlainPDF ? .zero : pageSize,
                verticalBooklet: settings.theme.flow == .vertical && settings.theme.supports(source.format)
                    && settings.layout.kind == .booklet,
                mixesImagePages: source.format == .image && settings.usesPerPageOrientation
                    && Set(sourcePageSizes?.sizes.map { $0.width > $0.height } ?? []).count > 1,
                theme: source.children != nil || source.format.usesPrintTheme ? settings.theme : nil,
                typeface: source.children != nil || isThemed ? settings.typeface : nil,
                textScale: source.children != nil || source.format.usesPrintTheme ? settings.textScale : nil,
                code: source.children != nil || source.format.usesPrintTheme ? settings.code : nil,
                preset: source.children != nil || source.format.usesHTMLPreset ? settings.preset : nil,
                margins: isPlainPDF ? .zero : margins,
                orgReading: source.format == .org || source.children != nil ? settings.orgReading : nil,
                latexComposition: settings.latexComposition,
                usesDocumentWidth: source.format == .latex
                    && (settings.theme.formats == [.latex]
                        || settings.options.latexMargins?.applies(to: settings.theme) == true),
                allowsJavaScript: source.children != nil
                    ? settings.allowsJavaScriptInHTML : source.allowsJavaScript(settings),
                smartRemoval: source.format == .html ? settings.smartRemoval : nil,
                opensDetails: source.format == .html && settings.opensDetails,
                slides: source.format == .html ? settings.slides : nil,
                binderStartsOnFront: source.children != nil && settings.binderStartsOnFront,
                binderOrientation: source.children == nil ? nil : settings.paperOrientation,
                binderLayout: source.children == nil ? nil : settings.layout,
                finish: isThemed ? settings.finish : nil,
                usesRightPages: isThemed && settings.layout.hasFacingPages && settings.finish.breaks.usesRightPages,
                mirrorsMargins: !isPlainPDF && source.children == nil
                    && settings.layout.mirrorsMargins(options: settings.options),
                rightBound: !isPlainPDF && settings.layout.mirrorsMargins(options: settings.options)
                    && settings.layout.isRightBound,
                contentsLanguage: isThemed && (settings.finish.toc.mode == .front || settings.finish.links == .endnotes)
                    ? settings.pageLanguage : nil,
                hasNotes: settings.activeNotes != nil,
                textNotes: isThemed
                    ? settings.activeNotes.map {
                        FinishedPagePlan.Notes(
                            placement: $0.placement, layoutKind: settings.layout.kind,
                            bookletBinding: settings.layout.bookletBinding)
                    } : nil)
            let logical: Logical
            if let cache, cache.key == key {
                logical = cache.logical
            } else {
                var requiredFolderAccess: URL?
                var issues: [PrintIssue] = []
                var diagrams: [RenderedDiagram] = []
                var composingSource: Data?
                var binderOutput: BinderOutput?
                var finishing = FinishedPages()
                let document: PDFDocument
                let unreadable: [URL]
                let candidates: [SmartRemovalCandidate]
                if let children = source.children {
                    let output = try await binder(children, settings: settings)
                    binderOutput = output
                    guard let selectable = StandalonePage.selectableDocument(output.document) else {
                        throw RenderingError.invalidPDF
                    }
                    document = selectable
                    unreadable = []
                    candidates = []
                    issues = output.issues
                    diagrams = output.diagrams
                    requiredFolderAccess = output.requiredFolderAccess
                    finishing.blankPages = output.blankPages
                } else if let images = source.images {
                    (document, unreadable) = try await imageBundle(images, settings: settings)
                    candidates = []
                } else {
                    var outputSettings = settings
                    outputSettings.markdownChanges = []
                    if let onReadingPreview,
                        source.format == .csv
                            || (source.format == .plainText && source.data.count > ReadingPrefix.textThresholdBytes)
                    {
                        input = try await readingInput(source, settings: outputSettings, onPreview: onReadingPreview)
                    }
                    let result = try await logicalDocument(source, settings: outputSettings, input: input)
                    if source.format == .html, generation == currentGeneration {
                        sourcePageRule = (source, PageRule.orientation(of: result.pageRules))
                    }
                    requiredFolderAccess = result.requiredFolderAccess
                    issues = result.issues
                    diagrams = result.diagrams
                    composingSource = result.drawingBytes
                    document = result.document
                    finishing = result.finishing
                    candidates =
                        source.format == .html && settings.smartRemoval != nil
                        ? SmartRemovalScript.candidates(fromJSON: result.preparationResult ?? "") : []
                    unreadable = []
                }
                try Task.checkCancellation()
                guard document.pageCount > 0 else { throw RenderingError.invalidPDF }
                logicalSerial += 1
                logical = Logical(
                    id: logicalSerial, document: document,
                    viewDocument: source.format == .image ? ImagePageRenderer.viewDocument(of: document) : document,
                    unreadable: unreadable, candidates: candidates)
                logical.composingSource = composingSource
                logical.requiredFolderAccess = requiredFolderAccess
                logical.issues = issues
                logical.diagrams = diagrams
                logical.hasFormulas =
                    binderOutput?.hasFormulas ?? (finishing.bodyHTML?.contains("class=\"math math-") == true)
                logical.unreadableDocuments = binderOutput?.unreadable ?? []
                logical.binderDocuments = binderOutput?.documents ?? [:]
                logical.binderPageStarts = binderOutput?.pageStarts ?? [:]
                logical.binderPageSizes = binderOutput?.pageSizes ?? []
                if let text = finishing.sourceText {
                    // Paper backgrounds and mirrored margins move link annotations with the ink. Read the final
                    // positions once, before any binder, preview or export receives the cached document.
                    logical.sourceLines = SourceLineLocation.take(from: document)
                    SourcePaperText.attach(
                        text, to: document, options: settings.code.sourceBlock,
                        language: finishing.facts?.sourceLanguage)
                }
                logical.finishing = finishing
                logicalRenderCount += 1
                // An older suspended render must not overwrite the cache of a newer request.
                if generation == currentGeneration { cache = (key, logical) }
            }
            let marks = try await screenMarks(for: source, settings: settings, logical: logical)
            if source.children != nil, settings.paperOrientation == .auto, settings.layout.kind != .booklet {
                // Children keep their own logical orientation; only the shared output follows the majority.
                landscape = PaperOrientation.auto.isLandscape(pageSizes: logical.binderPageSizes)
                settings.layout = settings.layout.oriented(landscape)
            }
            let pages = try await noted(logical, source: source, settings: settings)
            try Task.checkCancellation()
            let selection: PageRange.Selection
            if logical.finishing.facts?.beamerPageSize != nil, let slide = settings.slides?.onlyIndex,
                (0..<logical.document.pageCount).contains(slide)
            {
                // The current slide is selected in reading order, before the tray inserts writing pages.
                let notes = Set(pages.finishing.notePages)
                let slides = (0..<pages.document.pageCount).filter { !notes.contains($0) }
                selection = PageRange.Selection(pages: Array(slides.dropFirst(slide).prefix(1)), isOutOfDocument: false)
            } else {
                selection = settings.pageRange.selection(pageCount: pages.document.pageCount)
            }
            let furniture = furnitureContext(source, logical: pages, settings: settings)
            let orientsEachPage = settings.usesPerPageOrientation && (source.format == .pdf || source.format == .image)
            let plan =
                selection.pages.map { Imposition.plan(pages: $0, layout: settings.layout) }
                ?? Imposition.plan(pageCount: pages.document.pageCount, layout: settings.layout)
            if logical.hasFormulas, !settings.indexesFormulas, pages.formulaIndex == nil {
                pages.formulaIndex = PaperFormulaIndex(
                    source: source, settings: requestedSettings, pageCount: pages.viewDocument.pageCount)
            }
            return PreparedRender(
                id: currentGeneration, resolvedOrientation: landscape ? .landscape : .portrait, layout: settings.layout,
                logicalDocument: pages.document, viewDocument: pages.viewDocument, plan: plan,
                summary: PrintSummary(plan: plan),
                requiredFolderAccess: pages.requiredFolderAccess, unreadableImageURLs: pages.unreadable,
                smartRemovalCandidates: pages.candidates, issues: pages.issues,
                changeMarks: marks, diagrams: pages.diagrams, sourceLines: pages.sourceLines.locations,
                sourceLineCount: pages.sourceLines.lastNumber,
                formulaIndex: pages.formulaIndex,
                unreadableDocumentURLs: pages.unreadableDocuments, binderDocuments: pages.binderDocuments,
                binderPageStarts: pages.binderPageStarts,
                facts: pages.finishing.facts, addedContentsPages: pages.finishing.contentsPageCount,
                blankPages: pages.finishing.blankPages, notePages: pages.finishing.notePages,
                pageSelection: selection,
                viewFurniture: pages.viewDocument === pages.document && source.images == nil
                    ? Self.viewFurniture(
                        of: pages.document, layout: settings.layout, options: settings.options,
                        orientsEachPage: orientsEachPage, context: furniture) : [:],
                sourceBytes: pages.composingSource,
                sheetKey: SheetKey(
                    logicalID: pages.id, layout: settings.layout, options: settings.options,
                    orientsEachPage: orientsEachPage, furniture: furniture, pages: selection.pages,
                    // As `mirroringMargins` and `noted` moved them: texts and images, and never a note page.
                    sides: PDFComposer.LaidOutSides(
                        movesContent: source.format != .pdf && source.children == nil,
                        fixedPages: Set(pages.finishing.notePages))),
                options: settings.options)
        } catch {
            throw Self.renderingError(error)
        }
    }

    private func screenMarks(for source: DocumentSource, settings: RenderSettings, logical: Logical) async throws
        -> [ChangeMark]
    {
        let requests = settings.markdownChanges
        guard source.format.supportsChangeMarks, !requests.isEmpty else { return [] }
        let needsInk = settings.changeTextHex != nil && requests.contains { !$0.isShort }
        func tinted(_ marks: [ChangeMark]) -> [ChangeMark] {
            marks.map { mark in
                var result = mark
                result.backgroundHex = settings.changeBackgroundHex
                result.textHex = settings.changeTextHex
                return result
            }
        }
        if logical.markRequests == requests, !needsInk || logical.hasInkStencil {
            return tinted(logical.changeMarks)
        }

        // Geometry comes from a disposable pass; output always uses the anchor-free cached PDF.
        // Structural selectors in a theme can slightly offset these rectangles, never the output.
        var geometry = settings
        geometry.changeTextHex = nil
        guard let measured = try? await logicalDocument(source, settings: geometry) else {
            try Task.checkCancellation()
            return []
        }
        try Task.checkCancellation()
        var marks = ChangeMarkAnchors.extract(from: measured.document, requests: requests).filter {
            $0.pageIndex < logical.document.pageCount
        }
        var complete = false
        if needsInk, measured.document.pageCount == logical.document.pageCount,
            let stencil = try? await logicalDocument(source, settings: settings),
            stencil.document.pageCount == measured.document.pageCount
        {
            // Both passes carry the same anchors. Compare the printed blocks themselves, independent of how PDFKit
            // groups coloured glyphs into words, runs or synthetic whitespace elsewhere on the page.
            let inkMarks = ChangeMarkAnchors.extract(from: stencil.document, requests: requests)
            let drawing = ChangeTextDrawing(stencil.document)
            let matching = ChangeMarkAnchors.matchingGeometry(marks, inkMarks)
            for index in matching
            where !marks[index].isShort
                && ChangeMarkAnchors.matchesCleanPage(
                    marks[index], measured: measured.document, clean: logical.document)
            {
                marks[index].textDrawing = drawing
            }
            complete =
                marks.contains { $0.textDrawing != nil } && marks.allSatisfy { $0.isShort || $0.textDrawing != nil }
        }
        try Task.checkCancellation()
        logical.changeMarks = marks
        logical.markRequests = requests
        logical.hasInkStencil = complete
        return tinted(marks)
    }

    /// The pages with their note pages, or the pages themselves without any. Everything here is drawn, so it stays
    /// quick enough to follow the sheet's sliders; the pages laid out by WebKit come from the cache as they are.
    private func noted(_ logical: Logical, source: DocumentSource, settings: RenderSettings) async throws -> Logical {
        guard let notes = settings.activeNotes else { return logical }
        let pageSize = settings.logicalPageSize
        let isPlainPDF = source.format == .pdf
        // A text is already on its sides: it moves before its paper goes under it, which must not move with it.
        let moves =
            !isPlainPDF && logical.finishing.plan == nil && settings.layout.mirrorsMargins(options: settings.options)
        let shift = moves ? settings.layout.versoContentShift(options: settings.options) : 0
        let key = NotedKey(
            notes: notes, layoutKind: settings.layout.kind, pageSize: pageSize, mirrorShift: shift,
            rightBound: settings.layout.isRightBound)
        if let noted = logical.noted, noted.key == key { return noted.logical }
        let plan =
            logical.finishing.plan
            ?? FinishedPagePlan(
                bodyPageCount: logical.document.pageCount, contentsPageCount: 0, rightPageStarts: [],
                notes: .init(
                    placement: notes.placement, layoutKind: settings.layout.kind,
                    bookletBinding: settings.layout.bookletBinding,
                    chapterEnds: notes.placement == .chapterEnd
                        ? Self.chapterEnds(of: source, in: logical.document) : []
                ))
        let notePages = try await NotePageDrawing.document(
            style: notes.style, pageSize: pageSize, pageNumbers: plan.notePages.map { $0 + 1 })
        // The cached pages stay as they are for the view mode, which shows the document without notes.
        guard let data = logical.document.dataRepresentation(), let document = PDFDocument(data: data) else {
            throw RenderingError.invalidPDF
        }
        for (offset, index) in plan.notePages.enumerated() {
            guard let page = notePages.page(at: offset), let copy = StandalonePage.copy(of: page) else {
                throw RenderingError.invalidPDF
            }
            document.insert(copy, at: index)
        }
        let output: PDFDocument
        if shift != 0 {
            // A note page keeps the margins of its own style.
            let notes = Set(plan.notePages)
            output =
                PaperComposer.compose(
                    document, paper: nil,
                    shift: { !notes.contains($0) && settings.layout.swapsSides(onPage: $0) ? shift : 0 })
                ?? document
        } else {
            output = document
        }
        logicalSerial += 1
        let noted = Logical(
            id: logicalSerial, document: output, viewDocument: output, unreadable: logical.unreadable,
            candidates: logical.candidates)
        let places = plan.pages.indices.filter { plan.pages[$0] != .note }
        noted.diagrams = logical.diagrams.compactMap {
            guard places.indices.contains($0.pageIndex) else { return nil }
            var diagram = $0
            diagram.pageIndex = places[$0.pageIndex]
            if output !== document {
                diagram.rect = DiagramGeometry.redrawn(
                    diagram.rect, on: document.page(at: diagram.pageIndex),
                    shift: settings.layout.swapsSides(onPage: diagram.pageIndex) ? shift : 0)
            }
            return diagram
        }
        noted.requiredFolderAccess = logical.requiredFolderAccess
        noted.unreadableDocuments = logical.unreadableDocuments
        // A text already counted its issues with the notes in place.
        noted.issues =
            logical.finishing.plan != nil
            ? logical.issues
            : logical.issues.map { issue in
                var issue = issue
                issue.pageNumber = issue.pageNumber.flatMap { number in
                    plan.bodyPageIndices.indices.contains(number - 1) ? plan.bodyPageIndices[number - 1] + 1 : number
                }
                return issue
            }
        noted.finishing = logical.finishing
        noted.sourceLines.lastNumber = logical.sourceLines.lastNumber
        noted.sourceLines.locations = logical.sourceLines.locations.mapValues { line in
            let page = places[line.pageIndex]
            let offset = settings.layout.swapsSides(onPage: page) ? shift : 0
            let rect =
                output === document
                ? line.rect : DiagramGeometry.redrawn(line.rect, on: document.page(at: page), shift: offset)
            return SourceLineLocation(pageIndex: page, rect: rect)
        }
        noted.finishing.blankPages = plan.blankPages
        noted.finishing.notePages = plan.notePages
        logical.noted = (key, noted)
        return noted
    }

    /// The pages that end a chapter of a document that does not go through the finish of a text.
    private static func chapterEnds(of source: DocumentSource, in document: PDFDocument) -> Set<Int> {
        switch source.format {
        case .pdf: return DocumentOutline.chapterEnds(of: PDFOutlineReader.entries(of: document))
        case .html:
            guard let html = structureHTML(of: source) else { return [] }
            let headings = DocumentOutline.headings(inHTML: html)
            let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            let pages = DocumentOutline.pages(
                of: headings, inPageTexts: texts, contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
            return DocumentOutline.chapterEnds(of: headings, pages: pages, inPageTexts: texts)
        default: return []
        }
    }

    private struct BinderOutput {
        let document = PDFDocument()
        var hasFormulas = false
        var documents: [URL: PDFDocument] = [:]
        var pageStarts: [URL: Int] = [:]
        var pageSizes: [CGSize] = []
        var unreadable: [URL] = []
        var issues: [PrintIssue] = []
        var requiredFolderAccess: URL?
        var blankPages: Set<Int> = []
        var diagrams: [RenderedDiagram] = []
    }

    private func binder(_ children: [DocumentSource], settings: RenderSettings) async throws -> BinderOutput {
        var output = BinderOutput()
        var occurrences: [String: Int] = [:]
        for child in children {
            try Task.checkCancellation()
            let key =
                (child.fileURL?.absoluteString ?? child.contentHash?.hex ?? ContentHash.of(child.data).hex) + ":"
                + child.format.rawValue
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let renderer: DocumentRenderer
            if let cached = childRenderers[key] {
                renderer = cached
            } else {
                renderer = DocumentRenderer(isSandboxed: isSandboxed, paginateWithResult: paginate)
                childRenderers[key] = renderer
            }
            let count = renderer.logicalRenderCount
            do {
                var childSettings = settings
                childSettings.binderStartsOnFront = false
                childSettings.finish.footnotes = .end
                childSettings.markdownChanges = []
                // Left and right belong to the bound pages, which a document on its own does not know.
                childSettings.options.mirrorsMargins = false
                childSettings.notes = NotePages()
                // The range counts the pages of the binder, not of each document in it.
                childSettings.pageRange = .all
                let prepared = try await renderer.prepare(child, settings: childSettings)
                try Task.checkCancellation()
                binderChildRenderCount += renderer.logicalRenderCount - count
                let document = prepared.logicalDocument
                let offset = BinderPagination.offsets(
                    pageCounts: [output.document.pageCount, document.pageCount],
                    startsOnFront: settings.binderStartsOnFront)[1]
                let pages = try (0..<document.pageCount).map { index in
                    guard let page = document.page(at: index), let copy = StandalonePage.copy(of: page) else {
                        throw RenderingError.invalidPDF
                    }
                    return copy
                }
                if offset > output.document.pageCount {
                    let blank = PDFPage()
                    blank.setBounds(
                        CGRect(origin: .zero, size: settings.logicalPageSize),
                        for: .mediaBox)
                    output.blankPages.insert(output.document.pageCount)
                    output.document.insert(blank, at: output.document.pageCount)
                }
                if prepared.formulaIndex != nil { output.hasFormulas = true }
                output.pageSizes += Self.pageSizes(of: document)
                for page in pages { output.document.insert(page, at: output.document.pageCount) }
                SourcePaperText.include(document, in: output.document, startingAt: offset)
                if let url = child.fileURL {
                    output.documents[url] = document
                    if document.pageCount > 0 { output.pageStarts[url] = offset }
                }
                let firstNumber = output.diagrams.last?.number ?? 0
                output.diagrams += prepared.diagrams.map {
                    var diagram = $0
                    diagram.pageIndex += offset
                    diagram.number += firstNumber
                    return diagram
                }
                let prefix = "\(key):\(occurrence):"
                output.issues += prepared.issues.map { issue in
                    PrintIssue(
                        id: prefix + issue.id, kind: issue.kind, detail: issue.detail,
                        imageFailure: issue.imageFailure, element: issue.element,
                        pageNumber: issue.pageNumber.map { $0 + offset }, rect: issue.rect,
                        locationKey: issue.locationKey.map { prefix + $0 })
                }
                output.requiredFolderAccess = output.requiredFolderAccess ?? prepared.requiredFolderAccess
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                if let url = child.fileURL { output.unreadable.append(url) }
            }
        }
        guard output.document.pageCount > 0 else { throw RenderingError.noReadableDocuments(output.unreadable) }
        return output
    }

    private static func pageSizes(of document: PDFDocument) -> [CGSize] {
        (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index), let ref = page.pageRef else { return nil }
            let size = ref.getBoxRect(.cropBox).intersection(ref.getBoxRect(.mediaBox)).size
            return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
        }
    }

    private func automaticLandscape(_ source: DocumentSource) async throws -> Bool {
        if source.format == .html {
            // Upright until the `@page` rules are known; render(_:settings:) lays a landscape document out again.
            guard let sourcePageRule, sourcePageRule.source == source else { return false }
            return sourcePageRule.orientation == .landscape
        }
        guard source.format == .pdf || source.format == .image else { return false }
        if let sourcePageSizes, sourcePageSizes.source == source {
            return PaperOrientation.auto.isLandscape(pageSizes: sourcePageSizes.sizes)
        }
        let currentGeneration = generation
        let sizes: [CGSize]
        if source.format == .pdf {
            guard let document = PDFDocument(data: source.data) else { throw RenderingError.invalidPDF }
            guard !document.isEncrypted && !document.isLocked else { throw RenderingError.encryptedPDF }
            sizes = Self.pageSizes(of: document)
        } else {
            let loading = Task.detached(priority: Task.currentPriority) {
                guard let images = source.images else {
                    return [try ImagePageRenderer.contentSize(source.data)]
                }
                var sizes: [CGSize] = []
                for image in images {
                    try Task.checkCancellation()
                    do {
                        sizes.append(try ImagePageRenderer.contentSize(image.data()))
                    } catch is DocumentSource.Image.ContentChanged {
                        throw RenderingError.imageChanged(image.fileURL)
                    } catch {
                        try Task.checkCancellation()
                    }
                }
                return sizes
            }
            sizes = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: {
                loading.cancel()
            }
        }
        try Task.checkCancellation()
        let landscape = PaperOrientation.auto.isLandscape(pageSizes: sizes)
        if generation == currentGeneration { sourcePageSizes = (source, sizes) }
        return landscape
    }

    private func imageBundle(_ images: [DocumentSource.Image], settings: RenderSettings) async throws
        -> (PDFDocument, [URL])
    {
        let document = PDFDocument()
        var unreadable: [URL] = []
        for image in images {
            try Task.checkCancellation()
            // Read one image at a time, away from the main actor; its bytes go away once its page exists.
            let loading = Task.detached(priority: Task.currentPriority) { try image.data() }
            let data: Data
            do {
                data = try await withTaskCancellationHandler {
                    try await loading.value
                } onCancel: {
                    loading.cancel()
                }
            } catch is DocumentSource.Image.ContentChanged {
                throw RenderingError.imageChanged(image.fileURL)
            } catch {
                try Task.checkCancellation()
                unreadable.append(image.fileURL)
                continue
            }
            try Task.checkCancellation()
            do {
                let rendered = try await ImagePageRenderer().render(
                    data, pageSize: imagePageSize(settings),
                    margins: settings.layout.logicalMargins(options: settings.options),
                    autoRotatesPage: settings.usesPerPageOrientation)
                guard let page = StandalonePage.first(of: rendered) else {
                    throw ImagePageRenderer.RenderingError.invalidImage
                }
                document.insert(page, at: document.pageCount)
            } catch ImagePageRenderer.RenderingError.invalidImage {
                unreadable.append(image.fileURL)
            }
        }
        guard document.pageCount > 0 else { throw RenderingError.noReadableImages(unreadable) }
        return (Self.mirroringMargins(of: document, settings: settings), unreadable)
    }

    private func imagePageSize(_ settings: RenderSettings) -> CGSize {
        // Auto rotation starts with portrait so a minority portrait image retains its own shape.
        let layout = settings.usesPerPageOrientation ? settings.layout.oriented(false) : settings.layout
        return layout.logicalPageSize(options: settings.options)
    }

    private func logicalDocument(_ source: DocumentSource, settings: RenderSettings, input: ThemedInput? = nil)
        async throws -> WebPaginator.Result
    {
        switch source.format {
        case .zipArchive:
            throw RenderingError.unsupportedFormat
        case .pdf:
            guard let document = PDFDocument(data: source.data) else { throw RenderingError.invalidPDF }
            guard !document.isEncrypted && !document.isLocked else { throw RenderingError.encryptedPDF }
            guard document.pageCount > 0 else { throw RenderingError.invalidPDF }
            var result = WebPaginator.Result(document: document)
            result.drawingBytes = source.data
            return result
        case .image:
            return WebPaginator.Result(
                document: try await ImagePageRenderer().render(
                    source.data, pageSize: imagePageSize(settings),
                    margins: settings.layout.logicalMargins(options: settings.options),
                    autoRotatesPage: settings.usesPerPageOrientation))
        case .html:
            let input: WebPaginator.Source
            if source.isLiveSnapshot {
                let html = String(decoding: source.data, as: UTF8.self)
                input =
                    source.fileURL.map { .snapshot(html, directory: $0.deletingLastPathComponent()) }
                    ?? .html(html, baseURL: nil)
            } else if source.usesLoadedHTML, let url = source.fileURL {
                // The bytes identified by the binder hash stay authoritative until an explicit reload.
                let access =
                    resourceAccess(for: source)
                    ?? LocalResourceAccess(documentURL: url, folders: [url.deletingLastPathComponent()])
                input = .sandboxed(try Self.decodedText(source.data), access: access, followsOtherDocuments: true)
            } else if let url = source.fileURL {
                input = .file(url, readAccessURL: url.deletingLastPathComponent())
            } else {
                input = .html(try Self.decodedText(source.data), baseURL: source.htmlBaseURL)
            }
            var preparation =
                (settings.opensDetails ? HTMLSnapshotScript.openDetailsJavaScript + "\n" : "")
                + HTMLCleanupScript.javaScript(for: settings.preset)
            if let slides = settings.slides {
                let pageSize = settings.logicalPageSize
                let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
                // The paginating web view lays out one CSS pixel to a point.
                let printable = CGSize(
                    width: pageSize.width - margins.left - margins.right,
                    height: pageSize.height - margins.top - margins.bottom)
                preparation += "\n" + SlideDeckScript.printJavaScript(slides, printableSize: printable)
            }
            if let smartRemoval = settings.smartRemoval {
                preparation += "\n" + PaperCleanupScript.following(SmartRemovalScript.javaScript(for: smartRemoval))
            } else {
                preparation += "\n" + PaperCleanupScript.javaScript
            }
            let page = try await paginateCheckingIssues(
                PaginationRequest(
                    source: sandboxSource(input, for: source),
                    pageSize: settings.logicalPageSize,
                    margins: WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options)),
                    allowsJavaScript: source.allowsJavaScript(settings), preparationScript: preparation,
                    readsPageRules: true), source: source)
            guard settings.mirrorsLaidOutPages else { return page }
            var mirrored = WebPaginator.Result(
                document: Self.mirroringMargins(of: page.document, settings: settings),
                preparationResult: page.preparationResult, pageRules: page.pageRules,
                requiredFolderAccess: page.requiredFolderAccess)
            mirrored.issues = page.issues
            return mirrored
        case .markdown, .org, .plainText, .csv, .latex, .asciidoc, .quarto, .rMarkdown, .djot, .textile, .mediawiki,
            .rst,
            .docx,
            .notebook,
            .graphviz, .plantuml:
            var input = input
            if source.format == .plainText, settings.theme.flow == .vertical, input == nil {
                input = try await Self.readThemedInput(source, settings: settings, access: resourceAccess(for: source))
            }
            let flow =
                settings.theme.supports(source.format) && input?.fragment.sourceLanguage == nil
                ? settings.theme.flow : .horizontal
            let separatesPaper = WebPaginator.drawsClearPages && flow == .horizontal
            let page = try await Self.themedPage(
                source: source, settings: settings, access: resourceAccess(for: source), separatesPaper: separatesPaper,
                input: input)
            let fragment = page.fragment
            let directory = source.fileURL?.deletingLastPathComponent()
            let pageSize = settings.logicalPageSize
            if let info = fragment.latexClass, let size = info.beamerPageSize {
                let graphic = LaTeXGraphicPreparation.script(
                    in: fragment.body, layoutWidth: info.pageBox.textWidth * WebPaginator.printPixelsPerPoint,
                    layoutHeight: size.height * WebPaginator.printPixelsPerPoint)
                var result = try await paginateCheckingIssues(
                    PaginationRequest(
                        source: sandboxSource(.html(page.html, baseURL: directory), for: source),
                        pageSize: size, margins: .uniform(millimeters: 0), allowsJavaScript: false,
                        preparationScript: [graphic, try Self.beamerPreparation()].compactMap { $0 }.joined(
                            separator: "\n"),
                        readsPageRules: false, rendersDiagrams: page.diagrams, indexesFormulas: settings.indexesFormulas
                    ),
                    source: source)
                var facts = page.facts
                guard let data = result.preparationResult?.data(using: .utf8),
                    let slides = try? JSONDecoder().decode(BeamerPages.self, from: data),
                    slides.frames.count == result.document.pageCount
                else { throw WebPaginator.PaginationError.printFailed }
                facts.continuedBeamerFrames = slides.continued
                facts.beamerPageFrames = slides.frames
                if page.needsFolderAccess { result.requiredFolderAccess = directory }
                result.finishing.facts = facts
                result.finishing.bodyHTML = fragment.body
                return result
            }
            let margins = settings.layout.logicalMargins(options: settings.options)
            let themeScript = separatesPaper ? Self.themedPreparation(settings.theme) : settings.theme.script ?? ""
            let paperMargins = WebPaginator.Margins(margins)
            let layoutWidth =
                (pageSize.width - paperMargins.left - paperMargins.right) * WebPaginator.printPixelsPerPoint
            let checksVerticalLaTeXInk =
                source.format == .latex && settings.options.latexMargins?.applies(to: settings.theme) == true
                && settings.layout.kind != .handout3
            let latexFlow =
                source.format == .latex && settings.theme.formats == [.latex]
                && page.needsLaTeXFlow
            let codeScript =
                flow == .vertical ? "" : CodeFitScript.javaScript(for: settings.code, layoutWidth: layoutWidth) ?? ""
            let graphicScript =
                source.format == .latex
                ? LaTeXGraphicPreparation.script(
                    in: fragment.body, layoutWidth: layoutWidth,
                    layoutHeight: settings.theme.formats == [.latex]
                        ? (pageSize.height - paperMargins.top - paperMargins.bottom) * WebPaginator.printPixelsPerPoint
                        : nil
                ) ?? "" : ""
            let preparation: String?
            if settings.markdownChanges.isEmpty {
                // The theme's part goes last: its answer whether the theme has paper is the result of the whole.
                let locations = fragment.sourceLanguage == nil ? "" : SourceLineLocation.preparation
                let parts = [graphicScript, codeScript, locations, themeScript].filter { !$0.isEmpty }
                preparation = parts.isEmpty ? nil : parts.joined(separator: "\n")
            } else {
                // Cleanup catches script errors. Only an explicit success may replace the background-only drawing.
                // Emit the same anchors after decorations in both passes. In the stencil they attest that paint was ready.
                let needsInk = settings.changeTextHex != nil
                preparation = """
                    \(graphicScript)
                    \(codeScript)
                    const paper = await (async () => { \(themeScript) })();
                    \(needsInk ? ChangeMarkAnchors.textScript(settings.markdownChanges) : "")
                    \(ChangeMarkAnchors.javaScript(settings.markdownChanges, layoutWidth: layoutWidth, latexFlow: latexFlow || checksVerticalLaTeXInk))
                    return \(needsInk ? "null" : "paper");
                    """
            }
            var text: WebPaginator.Result
            if !latexFlow, flow == .horizontal, settings.finish.footnotes == .pageBottom,
                let plan = PageFootnotes.plan(for: page.paper.body),
                let placed = try await paginateFootnotes(
                    plan, page: page, source: source, settings: settings, preparation: preparation)
            {
                text = placed
            } else {
                text = try await paginateCheckingIssues(
                    PaginationRequest(
                        source: sandboxSource(.html(page.html, baseURL: directory), for: source), pageSize: pageSize,
                        margins: WebPaginator.Margins(margins),
                        allowsJavaScript: false,
                        preparationScript: preparation,
                        readsPageRules: false, drawsBackground: !separatesPaper,
                        rendersMermaid: page.mermaid, rendersDiagrams: page.diagrams,
                        latexPageNumbers: page.numbering, restartsAfterTitle: page.restartsAfterTitle,
                        collectsDiagrams: page.collectsDiagrams && settings.markdownChanges.isEmpty,
                        indexesFormulas: settings.indexesFormulas,
                        latexFlow: latexFlow,
                        latexMarginInk: source.format == .latex && settings.theme.formats == [.latex]
                            && (checksVerticalLaTeXInk || LaTeXFlowPaginator.hasMarginInk(in: fragment.body)),
                        checksVerticalLaTeXInk: checksVerticalLaTeXInk,
                        verticalBooklet: settings.layout.kind == .booklet,
                        verticalTextScale: settings.textScale, flow: flow),
                    source: source
                )
            }
            // A fallback is also reported by its printed anchor. Keep that occurrence (and page),
            // retaining the reader diagnostic when pagination supplied no matching figure.
            var printedPictures: [String: Int] = [:]
            for issue in text.issues where issue.kind == .latex && issue.element == .figure {
                printedPictures[issue.detail, default: 0] += 1
            }
            for (offset, detail) in fragment.readingIssues.enumerated() {
                let kind: PrintIssue.Kind =
                    switch source.format {
                    case _ where detail == StackSpace.limitIssue: .nestingLimit
                    case _ where detail == StackSpace.omissionIssue: .nestingOmission
                    case .org where detail == OrgConverter.contentsLimitIssue: .contentsLimit
                    case .rst: .rst
                    case .markdown: .bibliography
                    default: .latex
                    }
                if kind == .latex, let count = printedPictures[detail], count > 0 {
                    printedPictures[detail] = count - 1
                    continue
                }
                text.issues.append(PrintIssue(id: "\(kind.rawValue)-reader-\(offset)", kind: kind, detail: detail))
            }
            if page.needsFolderAccess { text.requiredFolderAccess = directory }
            text = try await finished(text, fragment: fragment, facts: page.facts, source: source, settings: settings)
            text.finishing.sourceText = fragment.sourceText
            guard separatesPaper, text.preparationResult == "paper" else { return text }
            let paperHTML = PaperBackground.document(
                theme: settings.theme, format: source.format, baseURL: directory,
                language: fragment.language ?? settings.pageLanguage,
                textScale: settings.textScale, typeface: settings.typeface,
                pageSize: pageSize, margins: margins, pixelsPerPoint: WebPaginator.printPixelsPerPoint)
            try PageLayoutLimits.checkHTML(bytes: paperHTML.utf8.count, sourceBytes: source.data.count)
            // A paper that cannot be drawn leaves the text on white, as a theme without one; a cancelled render stops.
            let paper: WebPaginator.Result
            do {
                paper = try await paginate(
                    PaginationRequest(
                        source: sandboxSource(.html(paperHTML, baseURL: directory), for: source), pageSize: pageSize,
                        margins: .uniform(millimeters: 0), allowsJavaScript: false,
                        preparationScript: PaperBackground.opaqueScript, readsPageRules: false))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                return text
            }
            guard let paperPage = paper.document.page(at: 0),
                let composed = PaperComposer.compose(text.document, paper: paperPage)
            else { return text }
            var result = WebPaginator.Result(
                document: composed, preparationResult: text.preparationResult, pageRules: text.pageRules,
                requiredFolderAccess: text.requiredFolderAccess ?? paper.requiredFolderAccess)
            result.issues = text.issues
            result.diagrams = text.diagrams.map {
                var diagram = $0
                diagram.rect = DiagramGeometry.redrawn(diagram.rect, on: text.document.page(at: diagram.pageIndex))
                return diagram
            }
            result.finishing = text.finishing
            return result
        }
    }

    struct BeamerPages: Decodable {
        let frames: [Int]
        let continued: Int
    }

    static func beamerPreparation() throws -> String {
        guard let url = Bundle.module.url(forResource: "latex-beamer-pages", withExtension: "js") else {
            throw WebPaginator.PaginationError.printFailed
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct ThemedPage {
        var numbering: LaTeXPageNumbers? {
            guard let info = fragment.latexClass,
                info.pageNumbers.needsRunningMarks || info.pageNumbers.needsExamTotals
                    || info.pageBackReferences || info.pageNumbers.usesJournalFurniture
                    || info.pageNumbers.usesClassPlain
                        && (info.hasChapters || fragment.body.contains("latex-title-block"))
                    || fragment.body.contains("class=\"toc\"")
                    || fragment.body.contains("latex-pageref") || fragment.body.contains("data-exam-pages")
                    || fragment.body.contains("data-latex-page-action") || fragment.body.contains("latex-titlepage")
                    || (info.hasSeparateTitlePage ?? info.hasChapters) && fragment.body.contains("latex-title-block")
            else { return nil }
            return info.pageNumbers
        }

        var restartsAfterTitle: Bool { fragment.latexClass?.pageBox.mirrorsSides == false }

        let fragment: HTMLFragment
        let needsLaTeXFlow: Bool
        let paper: HTMLFragment
        let html: String
        let facts: DocumentFacts
        let mermaid: Bool
        let diagrams: Bool
        var collectsDiagrams: Bool { mermaid || diagrams }
        let needsFolderAccess: Bool
    }

    private struct ThemedInput: Sendable {
        let fragment: HTMLFragment
        let needsFolderAccess: Bool
    }

    @concurrent private static func readThemedInput(
        _ source: DocumentSource, settings: RenderSettings, access: LocalResourceAccess?
    ) async throws -> ThemedInput {
        try Task.checkCancellation()
        // Set by the readers' file callbacks, which run on the conversion thread while this one waits.
        let needsFolderAccess = LockedFlag()
        guard
            let fragment = try Self.themedFragment(
                source, pageBreakLine: settings.finish.breaks.customLine, proof: settings.finish.proof,
                orgReading: settings.orgReading,
                composition: settings.latexComposition, textWidthPoints: settings.textWidthPoints(in: settings.layout),
                mapsMarkdownSource: !settings.markdownChanges.isEmpty, access: access,
                onDenied: { needsFolderAccess.set() },
                imageExists: { url in
                    if let access, !access.permits(url) {
                        needsFolderAccess.set()
                        return false
                    }
                    guard access != nil else { return FileManager.default.fileExists(atPath: url.path) }
                    do {
                        return try url.checkResourceIsReachable()
                    } catch {
                        let failure = error as NSError
                        // Missing extension candidates are normal during graphicx's search.
                        if failure.domain != NSCocoaErrorDomain
                            || ![CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue]
                                .contains(failure.code)
                        {
                            needsFolderAccess.set()
                        }
                        return false
                    }
                })
        else { throw RenderingError.unsupportedFormat }
        return ThemedInput(fragment: fragment, needsFolderAccess: needsFolderAccess.isSet)
    }

    @concurrent private static func themedPage(
        source: DocumentSource, settings: RenderSettings, access: LocalResourceAccess?, separatesPaper: Bool,
        input: ThemedInput?
    ) async throws -> ThemedPage {
        let read: ThemedInput
        if let input {
            read = input
        } else {
            read = try await readThemedInput(source, settings: settings, access: access)
        }
        var fragment = read.fragment
        let needsLaTeXFlow =
            source.format == .latex
            && (fragment.latexClass?.composition == .proof || fragment.latexClass?.resolvedStyle != nil
                || fragment.latexClass?.usesPublicationGrid == true
                || fragment.latexClass?.profile.usesGridFlow == true
                || LaTeXFlowPaginator.needed(in: fragment.body))
        if source.format != .markdown, !settings.markdownChanges.isEmpty {
            fragment.body = FragmentChanges.identifyingBlocks(in: fragment.body, for: settings.markdownChanges)
        }

        try Task.checkCancellation()
        let language = HTMLDocumentBuilder.language(for: fragment, fallback: settings.pageLanguage).code
        fragment.language = language
        var paper = fragment
        paper.body = settings.finish.links.apply(to: fragment.body, language: settings.pageLanguage)
        let html = try await builtHTML(paper, source: source, settings: settings, separatesPaper: separatesPaper)
        // Text and tables cannot emit diagram elements. Check markup before adding styles or duplicating it for notes.
        let markup = source.format != .plainText && source.format != .csv
        let mermaid =
            [.markdown, .org, .asciidoc, .quarto, .rMarkdown, .djot, .textile, .mediawiki].contains(source.format)
            && fragment.body.contains("class=\"mermaid-block\"")
        let diagrams =
            markup
            && (fragment.body.contains("graphviz-block") || fragment.body.contains("plantuml-block")
                || source.format == .latex && fragment.body.contains("class=\"tikz-block\""))
        try Task.checkCancellation()
        return ThemedPage(
            fragment: fragment, needsLaTeXFlow: needsLaTeXFlow, paper: paper, html: html,
            facts: DocumentFacts(fragment: fragment),
            mermaid: mermaid, diagrams: diagrams, needsFolderAccess: read.needsFolderAccess)
    }

    @concurrent static func builtHTML(
        _ fragment: HTMLFragment, source: DocumentSource, settings: RenderSettings, separatesPaper: Bool,
        isContents: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        var finishCSS = isContents ? "" : settings.finish.styleSheet
        if source.format == .latex, settings.layout.kind != .handout3,
            settings.theme.formats == [.latex] || settings.options.latexMargins?.applies(to: settings.theme) == true
        {
            finishCSS += RenderSettings.documentWidthCSS
        }
        let html = try HTMLDocumentBuilder.build(
            fragment: fragment, format: source.format, theme: settings.theme,
            baseURL: source.fileURL?.deletingLastPathComponent(),
            language: settings.pageLanguage, textScale: settings.textScale, typeface: settings.typeface,
            removesPaper: separatesPaper,
            finish: finishCSS, code: isContents ? CodeStyle() : settings.code
        ) {
            try PageLayoutLimits.checkHTML(bytes: $0, sourceBytes: source.data.count)
        }
        try PageLayoutLimits.checkHTML(bytes: html.utf8.count, sourceBytes: source.data.count)
        try Task.checkCancellation()
        return html
    }

    /// The pages of a text with what the print finish adds to them: the contents in front, a blank before a chapter
    /// that would fall on a left-hand page, and the margins of the left-hand pages turned the other way round.
    private func finished(
        _ text: WebPaginator.Result, fragment: HTMLFragment, facts: DocumentFacts, source: DocumentSource,
        settings: RenderSettings
    ) async throws -> WebPaginator.Result {
        var result = text
        result.finishing.facts = facts
        let finish = settings.finish
        let usesRightPages = settings.layout.hasFacingPages && finish.breaks.usesRightPages
        let wantsContents = finish.toc.mode == .front && !facts.headings.isEmpty
        let notes = settings.activeNotes
        result.finishing.bodyHTML = fragment.body
        result.finishing.showsSourceContents = finish.toc.showsSourceContents
        guard usesRightPages || wantsContents || settings.mirrorsLaidOutPages || notes != nil else { return result }
        let pageCount = text.document.pageCount
        var plan = FinishedPagePlan(bodyPageCount: pageCount, contentsPageCount: 0, rightPageStarts: [])
        var contents: PDFDocument?
        if usesRightPages || wantsContents || notes != nil {
            let showsSourceContents = finish.toc.showsSourceContents
            let pageTexts = (0..<pageCount).map { text.document.page(at: $0)?.string ?? "" }
            let headingPages = DocumentOutline.pages(
                of: facts.headings, inPageTexts: pageTexts,
                contentsEntries: showsSourceContents ? DocumentOutline.sourceContentsEntries(inHTML: fragment.body) : []
            )
            let insertion = notes.map {
                FinishedPagePlan.Notes(
                    placement: $0.placement, layoutKind: settings.layout.kind,
                    bookletBinding: settings.layout.bookletBinding,
                    chapterEnds: $0.placement == .chapterEnd
                        ? DocumentOutline.chapterEnds(of: facts.headings, pages: headingPages, inPageTexts: pageTexts)
                        : [])
            }
            let starts =
                usesRightPages
                ? FinishedPagePlan.rightPageStarts(
                    headings: facts.headings, pages: headingPages,
                    followsHeading: DocumentOutline.headingsUnderHeadings(inHTML: fragment.body), rules: finish.breaks)
                : []
            plan = FinishedPagePlan(
                bodyPageCount: pageCount, contentsPageCount: 0, rightPageStarts: starts, notes: insertion)
            // The numbers in the contents depend on how many pages the contents take, which the numbers can change.
            // A layout counts once it takes the pages it was numbered for.
            var plannedPageCount = 1
            for _ in 0..<(wantsContents ? Self.contentsLayoutLimit : 0) {
                plan = FinishedPagePlan(
                    bodyPageCount: pageCount, contentsPageCount: plannedPageCount, rightPageStarts: starts,
                    notes: insertion)
                let pages = try await contentsPages(
                    PaperContents.entries(
                        headings: facts.headings,
                        pageNumbers: headingPages.map { $0.map { plan.bodyPageIndices[$0] + 1 } },
                        depth: finish.toc.depth), source: source, settings: settings)
                contents = pages
                if pages.pageCount == plannedPageCount { break }
                plannedPageCount = pages.pageCount
            }
            // A contents that never settled keeps all its pages, so the pages after it stay in step with the last one.
            if let contents, contents.pageCount != plan.contentsPageCount {
                plan = FinishedPagePlan(
                    bodyPageCount: pageCount, contentsPageCount: contents.pageCount, rightPageStarts: starts,
                    notes: insertion)
            }
        }
        let document = Self.assembled(text.document, contents: contents, plan: plan, settings: settings)
        let mirrored = Self.mirroringMargins(of: document, settings: settings, plan: notes != nil ? plan : nil)
        var finished = WebPaginator.Result(
            document: mirrored,
            preparationResult: text.preparationResult, pageRules: text.pageRules,
            requiredFolderAccess: text.requiredFolderAccess)
        if !text.diagrams.isEmpty {
            // assembled() leaves note pages to noted(); the side of the paper already includes them.
            let beforeNotes = plan.pages.filter { $0 != .note }
            let bodyPlaces = beforeNotes.indices.filter {
                if case .body = beforeNotes[$0] { return true }
                return false
            }
            finished.diagrams = text.diagrams.compactMap {
                guard bodyPlaces.indices.contains($0.pageIndex) else { return nil }
                var diagram = $0
                diagram.pageIndex = bodyPlaces[$0.pageIndex]
                if mirrored !== document {
                    let shift =
                        settings.layout.swapsSides(onPage: plan.bodyPageIndices[$0.pageIndex])
                        ? settings.layout.versoContentShift(options: settings.options) : 0
                    diagram.rect = DiagramGeometry.redrawn(
                        diagram.rect, on: document.page(at: diagram.pageIndex), shift: shift)
                }
                return diagram
            }
        }
        finished.issues = text.issues.map { issue in
            var issue = issue
            issue.pageNumber = issue.pageNumber.flatMap { number in
                plan.bodyPageIndices.indices.contains(number - 1) ? plan.bodyPageIndices[number - 1] + 1 : number
            }
            return issue
        }
        finished.finishing = FinishedPages(
            latexPages: text.finishing.latexPages, facts: facts, contentsPageCount: contents?.pageCount ?? 0,
            blankPages: plan.blankPages,
            plan: notes != nil ? plan : nil, pagePlan: plan, bodyHTML: fragment.body,
            showsSourceContents: finish.toc.showsSourceContents)
        return finished
    }

    private static let contentsLayoutLimit = 3

    /// The contents laid out like the text: the same theme, paper size and margins.
    private func contentsPages(
        _ entries: [PaperContents.Entry], source: DocumentSource, settings: RenderSettings
    ) async throws -> PDFDocument {
        let directory = source.fileURL?.deletingLastPathComponent()
        let flow = settings.theme.supports(source.format) ? settings.theme.flow : .horizontal
        let separatesPaper = WebPaginator.drawsClearPages && flow == .horizontal
        let fragment = PaperContents.fragment(
            entries: entries, look: settings.finish.toc.look,
            title: PaperContents.title(language: settings.pageLanguage))
        let html = try await Self.builtHTML(
            fragment, source: source, settings: settings, separatesPaper: separatesPaper, isContents: true)
        let script = separatesPaper ? Self.themedPreparation(settings.theme) : settings.theme.script
        return try await paginate(
            PaginationRequest(
                source: sandboxSource(.html(html, baseURL: directory), for: source),
                pageSize: settings.logicalPageSize,
                margins: WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options)),
                allowsJavaScript: false, preparationScript: script?.isEmpty == false ? script : nil,
                readsPageRules: false, drawsBackground: !separatesPaper,
                verticalBooklet: settings.layout.kind == .booklet,
                verticalTextScale: settings.textScale, flow: flow)
        ).document
    }

    /// Adds to the document itself, so that the links between its pages keep pointing at them. The note pages go in
    /// later, in `noted(_:source:settings:)`.
    private static func assembled(
        _ body: PDFDocument, contents: PDFDocument?, plan: FinishedPagePlan, settings: RenderSettings
    ) -> PDFDocument {
        guard !plan.isUnchanged else { return body }
        var index = 0
        for page in plan.pages {
            switch page {
            case .note: continue
            case .body: break
            case .contents(let number):
                if let page = contents?.page(at: number), let copy = StandalonePage.copy(of: page) {
                    body.insert(copy, at: index)
                }
            case .blank:
                let blank = PDFPage()
                blank.setBounds(
                    CGRect(origin: .zero, size: settings.logicalPageSize),
                    for: .mediaBox)
                body.insert(blank, at: index)
            }
            index += 1
        }
        return body
    }

    /// Moves the content of the even pages, which are left-hand pages, so that the side of the binding keeps its
    /// margin. The pages were laid out with the same width, so moving them is all it takes.
    /// - Parameter plan: Where the pages end up once the notes are in, when that is what decides their sides.
    private static func mirroringMargins(
        of document: PDFDocument, settings: RenderSettings, plan: FinishedPagePlan? = nil
    ) -> PDFDocument {
        guard settings.mirrorsLaidOutPages || plan != nil else { return document }
        guard settings.layout.mirrorsMargins(options: settings.options) else { return document }
        let shift = settings.layout.versoContentShift(options: settings.options)
        let places = plan.map { plan in plan.pages.indices.filter { plan.pages[$0] != .note } }
        guard shift != 0, document.pageCount > 1 || places != nil || settings.layout.isRightBound else {
            return document
        }
        return PaperComposer.compose(
            document, paper: nil,
            shift: { index in
                let place = places.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? index
                return settings.layout.swapsSides(onPage: place) ? shift : 0
            }) ?? document
    }

    private func furnitureContext(
        _ source: DocumentSource, logical: Logical, settings: RenderSettings
    ) -> PageFurniture.Context {
        let furniture = settings.options.furniture
        guard !furniture.isEmpty else { return PageFurniture.Context() }
        let fileName = settings.documentName ?? source.fileURL?.lastPathComponent ?? ""
        let fallback = (fileName as NSString).deletingPathExtension
        let title: String?
        switch source.format {
        case .pdf where source.children == nil:
            title = logical.document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        case .html: title = DocumentOutline.title(ofHTML: String(decoding: source.data, as: UTF8.self))
        default: title = logical.finishing.facts?.title
        }
        var context = PageFurniture.Context(
            fileName: fileName, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
            date: furniture.dateText(now(), language: settings.pageLanguage),
            blankPages: logical.finishing.blankPages.union(logical.finishing.notePages),
            chapters: furniture.uses(.chapter) ? Self.chapters(of: logical) : [])
        if let footer = settings.latexFooter {
            context.latexFooter = footer
            let destinations = logical.finishing.pagePlan?.bodyPageIndices ?? Array(0..<logical.document.pageCount)
            var initial = latexClassInfo(for: source, composition: settings.latexComposition).pageNumbers
            let measured = logical.finishing.latexPages
            for (bodyIndex, page) in destinations.enumerated() {
                let number =
                    measured.indices.contains(bodyIndex)
                    ? measured[bodyIndex]
                    : LaTeXPageReferences.Page(initial)
                context.pageLabels[page] = number.label
                if number.lines.isEmpty {
                    context.blankPages.insert(page)
                } else {
                    context.documentLines[page] = number.lines
                }
                initial.advance()
            }
        }
        return context
    }

    /// The date a header or footer laid out with `settings` shows today; nil when it shows no date. Pages laid out on
    /// another day show that day's, so they are laid out again before they are shown or printed today.
    public func furnitureDate(for settings: RenderSettings) -> String? {
        let furniture = settings.options.furniture
        guard furniture.uses(.date) else { return nil }
        return furniture.dateText(now(), language: settings.pageLanguage)
    }

    /// What the sheets draw on each page that the view mode shows as it is, by the page's index. The view mode has
    /// no page range, so each page stands at its own place among the printed ones. A page of another size than the
    /// layout's logical page, such as a PDF's own page, is scaled into its place on the sheet, while the header and
    /// footer are measured on the logical page around it: its paper is not the box they stand in, so it has none.
    static func viewFurniture(
        of document: PDFDocument, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool,
        context: PageFurniture.Context
    ) -> [Int: FurniturePlacement] {
        guard !options.furniture.isEmpty else { return [:] }
        var placements: [Int: FurniturePlacement] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox).size
            let size = page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
            // As the composer turns the sheet of a single-sided layout to each page.
            let pageLayout =
                orientsEachPage && layout.kind == .normal && layout.duplex == .none
                ? layout.oriented(size.width > size.height) : layout
            guard
                let placement = PDFComposer.furniture(
                    onPage: index, at: index, pageCount: document.pageCount, layout: pageLayout, options: options,
                    context: context),
                abs(placement.pageSize.width - size.width) < 0.5, abs(placement.pageSize.height - size.height) < 0.5
            else { continue }
            placements[index] = placement
        }
        return placements
    }

    /// The chapter in force on each page, read from the finished pages. Reading the text of every page takes time, so
    /// this runs only for a header or footer that names the chapter.
    private static func chapters(of logical: Logical) -> [String] {
        let finishing = logical.finishing
        guard let facts = finishing.facts, !facts.headings.isEmpty, let body = finishing.bodyHTML else { return [] }
        let plan = finishing.pagePlan
        let places = plan?.bodyPageIndices ?? Array(0..<logical.document.pageCount)
        let pageTexts = places.map { logical.document.page(at: $0)?.string ?? "" }
        let headingPages = DocumentOutline.pages(
            of: facts.headings, inPageTexts: pageTexts,
            contentsEntries: finishing.showsSourceContents ? DocumentOutline.sourceContentsEntries(inHTML: body) : [])
        return PageChapters.titles(headings: facts.headings, pages: headingPages, pageCount: places.count, plan: plan)
    }

    /// A failed measurement leaves the original single-pagination path in charge, with no partially moved notes.
    private func paginateFootnotes(
        _ plan: PageFootnotes.Plan, page: ThemedPage, source: DocumentSource,
        settings: RenderSettings, preparation: String?
    ) async throws -> WebPaginator.Result? {
        do {
            let pageSize = settings.logicalPageSize
            let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
            let directory = source.fileURL?.deletingLastPathComponent()
            func request(_ body: String, collectsDiagrams: Bool = false) async throws -> PaginationRequest {
                var fragment = page.paper
                fragment.body = body
                let html = try await Self.builtHTML(
                    fragment, source: source, settings: settings, separatesPaper: WebPaginator.drawsClearPages)
                return PaginationRequest(
                    source: sandboxSource(.html(html, baseURL: directory), for: source), pageSize: pageSize,
                    margins: margins, allowsJavaScript: false, preparationScript: preparation,
                    readsPageRules: false, drawsBackground: !WebPaginator.drawsClearPages,
                    rendersMermaid: page.mermaid, rendersDiagrams: page.diagrams,
                    latexPageNumbers: page.numbering, restartsAfterTitle: page.restartsAfterTitle,
                    collectsDiagrams: collectsDiagrams && page.collectsDiagrams && settings.markdownChanges.isEmpty,
                    indexesFormulas: collectsDiagrams && settings.indexesFormulas)
            }
            try Task.checkCancellation()
            let measured = try await paginateCheckingIssues(
                request(plan.measuringHTML(placing: plan.eligibleNotes)), source: source)
            try Task.checkCancellation()
            let measurement = try FootnotePlacer.measure(measured.document, plan: plan, placing: plan.eligibleNotes)
            let groups = try FootnotePlacer.groups(
                for: measurement, plan: plan,
                contentHeight: pageSize.height - margins.top - margins.bottom, textScale: settings.textScale)
            // A line with something drawn in its room (a tinted box, a float beside it) keeps its notes at the end; the
            // rest is laid out again without it. A document full of such lines is not worth more passes.
            var remaining = groups
            for _ in 0..<4 {
                guard !remaining.isEmpty else { return nil }
                let placing = remaining
                do {
                    let result = try await paginateCheckingIssues(
                        request(plan.reservingHTML(groups: placing), collectsDiagrams: true), source: source
                    ) {
                        try FootnotePlacer.compose($0, plan: plan, groups: placing, margins: margins)
                    }
                    try Task.checkCancellation()
                    return result
                } catch FootnotePlacer.PlacementError.inkInBand(let first) {
                    try Task.checkCancellation()
                    remaining.removeAll { $0.firstReference == first }
                }
            }
            return nil
        } catch let error as RenderingError {
            if case .tooLarge = error { throw error }
            try Task.checkCancellation()
            return nil
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return nil
        }
    }

    private func paginateCheckingIssues(
        _ request: PaginationRequest, source: DocumentSource,
        transform: ((PDFDocument) throws -> PDFDocument)? = nil
    ) async throws
        -> WebPaginator.Result
    {
        let wrapped = PaginationRequest(
            source: request.source, pageSize: request.pageSize, margins: request.margins,
            allowsJavaScript: request.allowsJavaScript,
            preparationScript: PrintIssueAnchors.following(
                request.preparationScript, themed: source.format.usesPrintTheme),
            readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
            rendersMermaid: request.rendersMermaid, rendersDiagrams: request.rendersDiagrams,
            latexPageNumbers: request.latexPageNumbers, restartsAfterTitle: request.restartsAfterTitle,
            collectsDiagrams: request.collectsDiagrams, indexesFormulas: request.indexesFormulas,
            composesLaTeXParagraphs: source.format == .latex,
            latexFlow: request.latexFlow,
            latexMarginInk: request.latexMarginInk, checksVerticalLaTeXInk: request.checksVerticalLaTeXInk,
            verticalBooklet: request.verticalBooklet, verticalTextScale: request.verticalTextScale, flow: request.flow)
        let output = try await paginate(wrapped)
        let preparation = output.preparationResult.flatMap {
            try? JSONDecoder().decode(PrintIssueAnchors.Preparation.self, from: Data($0.utf8))
        }
        let document = try transform?(output.document) ?? output.document
        let access = resourceAccess(for: source)
        let issues = (preparation?.issues ?? []).map { issue in
            var issue = issue
            if issue.kind == .image {
                let url = URL(string: issue.detail)
                let file = url.flatMap { $0.isFileURL ? $0 : LocalResourceSchemeHandler.fileURL(for: $0) }
                issue.imageFailure = file.map { PrintIssueAnchors.imageFailure($0, access: access) } ?? .other
                issue.detail =
                    (file ?? url).map {
                        PrintIssue.imageName($0, directory: source.fileURL?.deletingLastPathComponent())
                    } ?? ""
            } else if issue.kind == .math || issue.kind == .mermaid {
                issue.detail = PrintIssue.excerpt(issue.detail)
            }
            return issue
        }
        var result = WebPaginator.Result(
            document: document,
            preparationResult: preparation.map { $0.previous } ?? output.preparationResult,
            pageRules: output.pageRules, requiredFolderAccess: output.requiredFolderAccess)
        result.finishing.latexPages = output.finishing.latexPages
        if let pass = output.diagramPass {
            result.diagrams = (try? pass.diagrams(transform: transform)) ?? []
            try Task.checkCancellation()
        }
        // Only the page contents are drawn by Quartz; restoring or removing link annotations does not alter them.
        if transform == nil { result.drawingBytes = output.drawingBytes }
        result.issues = PrintIssueAnchors.extract(from: document, issues: issues) + output.issues
        return result
    }

    func resourceAccess(for source: DocumentSource) -> LocalResourceAccess? {
        guard isSandboxed(), let file = source.fileURL else { return nil }
        return LocalResourceAccess(documentURL: file, folders: source.allowedResourceFolders)
    }

    func exportSource(_ input: WebPaginator.Source, for source: DocumentSource) -> WebPaginator.Source {
        sandboxSource(input, for: source)
    }

    private func sandboxSource(_ input: WebPaginator.Source, for source: DocumentSource) -> WebPaginator.Source {
        guard let access = resourceAccess(for: source) else { return input }
        switch input {
        case .html(let html, let base):
            return .sandboxed(base.map { WebPaginator.injectingBase($0, into: html) } ?? html, access: access)
        case .file:
            // The opened HTML file itself, which may go on to another document as it does outside the sandbox.
            return .sandboxed(nil, access: access, followsOtherDocuments: true)
        case .snapshot(let html, let directory):
            return .sandboxed(WebPaginator.injectingBase(directory, into: html), access: access)
        case .sandboxed:
            return input
        }
    }

    /// The theme's decorations, then the question whether the theme has paper. The decorations run in a function of
    /// their own, so neither a failure nor a return of theirs keeps the question from being asked.
    static func themedPreparation(_ theme: PrintTheme) -> String {
        guard let script = theme.script, !script.isEmpty else { return PaperBackground.detectionScript }
        return "try {\n  await (async () => {\n\(script)\n  })();\n} catch (_) {}\n" + PaperBackground.detectionScript
    }

    /// The HTML a document's headings and amount of text are read from, or nil for formats without one. It converts
    /// the whole source, so it is meant to run away from the main actor.
    public nonisolated static func structureHTML(
        of source: DocumentSource, proof: ProofMarks = .shown, orgReading: OrgReadingSettings = .init()
    ) -> String? {
        if source.format == .html { return TextDecoding.decode(source.data).text }
        return (try? themedFragment(source, proof: proof, orgReading: orgReading))??.body
    }

    /// Compare the last successful layout's source with this save off the UI actor, using the same converter options.
    public func changeRequests(
        from old: DocumentSource, to new: DocumentSource, finish: PrintFinish, orgReading: OrgReadingSettings = .init()
    ) async
        -> [MarkdownMarkRequest]
    {
        guard old.format == new.format, new.format.supportsChangeMarks, old.data != new.data else { return [] }
        let access = resourceAccess(for: new)
        let diff = Task.detached(priority: .utility) { () -> [MarkdownMarkRequest] in
            if new.format == .markdown {
                return MarkdownChanges.marks(
                    from: TextDecoding.decode(old.data).text, to: TextDecoding.decode(new.data).text)
            }
            func body(_ source: DocumentSource) -> String? {
                (try? Self.themedFragment(
                    source, pageBreakLine: finish.breaks.customLine, proof: finish.proof, orgReading: orgReading,
                    access: access,
                    imageExists: { url in
                        (access?.permits(url) ?? true) && FileManager.default.fileExists(atPath: url.path)
                    }))?.body
            }
            guard let before = body(old), !Task.isCancelled, let after = body(new), !Task.isCancelled else { return [] }
            return FragmentChanges.marks(from: before, to: after)
        }
        return await withTaskCancellationHandler {
            await diff.value
        } onCancel: {
            diff.cancel()
        }
    }

    /// The HTML of a format that prints with a theme, or nil for the formats that print as they are.
    nonisolated static func themedFragment(
        _ source: DocumentSource, pageBreakLine: String = "", proof: ProofMarks = .shown,
        orgReading: OrgReadingSettings = .init(),
        composition: LaTeXComposition = .document, textWidthPoints: Double? = nil, mapsMarkdownSource: Bool = false,
        access: LocalResourceAccess? = nil,
        onDenied: @escaping @Sendable () -> Void = {},
        imageExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> HTMLFragment? {
        let access =
            access
            ?? (SandboxEnvironment.isSandboxed
                ? source.fileURL.map { LocalResourceAccess(documentURL: $0, folders: source.allowedResourceFolders) }
                : nil)
        return switch source.format {
        case .markdown:
            try markdownFragment(
                source, pageBreakLine: pageBreakLine, proof: proof, mapsSource: mapsMarkdownSource,
                access: access, onDenied: onDenied)
        case .graphviz, .plantuml:
            DiagramConverter.convert(try decodedText(source.data), format: source.format)
        case .quarto, .rMarkdown:
            ComputationalMarkdown.convert(try decodedText(source.data), pageBreakLine: pageBreakLine, proof: proof)
        case .docx: try DocxConverter.convert(source.data)
        case .djot:
            try DjotConverter.convert(try decodedText(source.data))
        case .rst:
            RSTConverter.convert(try decodedText(source.data), directory: source.fileURL?.deletingLastPathComponent()) {
                url in
                guard access?.permits(url) != false else {
                    onDenied()
                    return false
                }
                return true
            }
        case .mediawiki:
            MediaWikiConverter.convert(
                try decodedText(source.data), directory: source.fileURL?.deletingLastPathComponent(),
                imageExists: imageExists)
        case .textile:
            try TextileConverter.convert(try decodedText(source.data))
        case .asciidoc:
            try AsciiDocConverter.convert(try decodedText(source.data))
        case .notebook:
            try NotebookConverter.convert(try decodedText(source.data), pageBreakLine: pageBreakLine, proof: proof)
        case .latex:
            try latexFragment(
                source, composition: composition, textWidthPoints: textWidthPoints, access: access, onDenied: onDenied,
                imageExists: imageExists)
        case .org:
            OrgConverter.convert(
                try decodedText(source.data), settings: orgReading,
                fileName: source.fileURL?.lastPathComponent ?? source.name)
        case .plainText, .csv:
            try DecodedPages(source).fragment()
        default: nil
        }
    }

    /// The language the conversion tells a plain text file to be. It converts the whole text, so it is for tests and
    /// for work off the main actor; a window takes the answer from the facts of the pages it laid out.
    public nonisolated static func sourceLanguage(of source: DocumentSource) -> SourceLanguage? {
        guard source.format == .plainText else { return nil }
        return (try? themedFragment(source, proof: .shown))??.sourceLanguage
    }

    private enum DecodedPages: Sendable {
        case text(String, original: String?, language: SourceLanguage?, highlights: Bool)
        case table(ArraySlice<[String]>, columnGroup: String?)

        init(_ source: DocumentSource) throws {
            if source.format == .plainText {
                guard source.data.count <= PageLayoutLimits.plainTextBytes else {
                    throw RenderingError.tooLarge(bytes: source.data.count)
                }
                let original = try DocumentRenderer.decodedText(source.data, preservingLineEndings: true)
                let name = source.name ?? source.fileURL?.lastPathComponent
                let normalized = TextDecoding.normalizeNewlines(original)
                let language = name.flatMap { SourceLanguage.detect(fileName: $0, text: { normalized }) }
                self = .text(
                    normalized, original: language == nil ? nil : original, language: language,
                    highlights: language != nil && normalized.utf16.count <= SyntaxHighlighter.maximumUTF16Count)
            } else {
                let text = try DocumentRenderer.decodedText(source.data)
                let delimiter: Character
                if let url = source.fileURL {
                    delimiter = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
                } else {
                    delimiter = CSVConverter.guessedDelimiter(of: text)
                }
                let rows = try CSVConverter.records(text, delimiter: delimiter) { count in
                    guard count <= PageLayoutLimits.csvRows else {
                        throw RenderingError.tooLarge(bytes: source.data.count)
                    }
                    if count.isMultiple(of: 1024) { try Task.checkCancellation() }
                }
                self = .table(rows[...], columnGroup: ReadingPrefix.csvColumnGroup(in: rows))
            }
        }

        func leading(sourceBytes: Int) -> Self? {
            switch self {
            case .text(let normalized, _, let language, _):
                // Number gutters and long-line scaling for source code depend on the entire block.
                guard language == nil, let prefix = ReadingPrefix.text(normalized, sourceBytes: sourceBytes) else {
                    return nil
                }
                return .text(prefix, original: nil, language: nil, highlights: false)
            case .table(let rows, let columnGroup):
                return ReadingPrefix.csv(rows).map { .table($0, columnGroup: columnGroup) }
            }
        }

        func fragment() -> HTMLFragment {
            switch self {
            case .text(let normalized, let original, let language, let highlights):
                var fragment = PlainTextConverter.convert(normalized, language: language, highlights: highlights)
                fragment.sourceText = original
                return fragment
            case .table(let rows, let columnGroup):
                return CSVConverter.table(rows, columnGroup: columnGroup)
            }
        }

        @concurrent static func read(_ source: DocumentSource) async throws -> Self {
            try Task.checkCancellation()
            return try Self(source)
        }

        @concurrent func input() async throws -> ThemedInput {
            try Task.checkCancellation()
            return ThemedInput(fragment: fragment(), needsFolderAccess: false)
        }

        @concurrent func leadingInput(sourceBytes: Int) async throws -> ThemedInput? {
            try Task.checkCancellation()
            return try await leading(sourceBytes: sourceBytes)?.input()
        }
    }

    private func readingInput(
        _ source: DocumentSource, settings: RenderSettings, onPreview: @MainActor (ReadingPreview) -> Void
    ) async throws -> ThemedInput {
        let decoded = try await DecodedPages.read(source)
        if let leading = try await decoded.leadingInput(sourceBytes: source.data.count) {
            // Keep the short layout out of the complete document and sheet caches. A failed preview is optional.
            let reader = DocumentRenderer(isSandboxed: isSandboxed, paginateWithResult: paginate)
            reader.now = now
            if let first = try? await reader.prepareOnce(source, settings: settings, suppliedInput: leading) {
                try Task.checkCancellation()
                onPreview(
                    ReadingPreview(
                        document: first.viewDocument, layout: first.layout, options: first.options,
                        furniture: first.viewFurniture))
            }
        }
        return try await decoded.input()
    }

    nonisolated static func decodedText(_ data: Data, preservingLineEndings: Bool = false) throws -> String {
        let decoded = TextDecoding.decode(data, preservingLineEndings: preservingLineEndings)
        // Core deliberately tolerates invalid byte sequences; printing must surface that data loss.
        guard String(data: data, encoding: decoded.encoding) != nil else { throw RenderingError.textDecodingFailed }
        let signatures: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
        ]
        if let (signature, encoding) = signatures.first(where: { data.starts(with: $0.0) }) {
            let payload = data.dropFirst(signature.count)
            guard let text = String(data: payload, encoding: encoding), text.data(using: encoding) == payload else {
                throw RenderingError.textDecodingFailed
            }
        }
        return decoded.text
    }
}
