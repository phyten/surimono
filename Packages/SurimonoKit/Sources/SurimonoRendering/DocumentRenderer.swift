import Foundation
import PDFKit
import SurimonoCore

public struct DocumentSource: Equatable, Sendable {
    public let data: Data
    public let fileURL: URL?
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
        return sameContent && lhs.fileURL == rhs.fileURL && lhs.format == rhs.format
            && lhs.images == rhs.images && lhs.children == rhs.children
            && lhs.allowedResourceFolders == rhs.allowedResourceFolders && lhs.isLiveSnapshot == rhs.isLiveSnapshot
            && lhs.usesLoadedHTML == rhs.usesLoadedHTML
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

    public init(data: Data, fileURL: URL? = nil, format: DocumentFormat) {
        self.init(data: data, fileURL: fileURL, format: format, isLiveSnapshot: false)
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
    public var textScale: Double
    /// The colors and blocks of the document's code; the print theme's own by default.
    public var code = CodeStyle()
    public var preset: HTMLCleanupPreset
    public var options: PrintOptions
    public var allowsJavaScriptInHTML: Bool
    /// Live HTML and paper must enforce the same combination of user and preset policy.
    public var allowsPageJavaScript: Bool { allowsJavaScriptInHTML && !preset.disablesJavaScript }
    public var smartRemoval: SmartRemovalRequest?
    /// HTML: open every `<details>` of the copy being laid out.
    public var opensDetails: Bool
    /// HTML that is a slide deck: print its slides one to a page, landscape in Auto.
    public var slides: SlidePrintRequest?
    public var binderStartsOnFront = false
    public var markdownChanges: [MarkdownMarkRequest]
    /// Where a text breaks and how it shows its table of contents.
    public var finish = PrintFinish()
    /// Pages to write on among the document's own; only a document of its own takes them, not a binder.
    public var notes = NotePages()
    /// The name the header and footer call the document by; without one, the name of its file.
    public var documentName: String?
    /// The language of what the app itself puts on the page, such as the title of the contents.
    public var pageLanguage = "ja"

    var usesPerPageOrientation: Bool {
        layout.kind == .normal && layout.duplex == .none && paperOrientation == .auto
    }

    var activeNotes: NotePages? { notes.isEnabled && notes.applies(to: layout) ? notes : nil }

    /// Note pages move the pages to other sides, so the margins are then turned round after the notes went in.
    var mirrorsLaidOutPages: Bool { layout.mirrorsMargins(options: options) && activeNotes == nil }

    public init(
        layout: PrintLayout, theme: PrintTheme, preset: HTMLCleanupPreset,
        options: PrintOptions = PrintOptions(), allowsJavaScriptInHTML: Bool = false,
        smartRemoval: SmartRemovalRequest? = nil, textScale: Double = 1, paperOrientation: PaperOrientation = .auto,
        opensDetails: Bool = false, slides: SlidePrintRequest? = nil, markdownChanges: [MarkdownMarkRequest] = []
    ) {
        self.markdownChanges = markdownChanges
        self.opensDetails = opensDetails
        self.slides = slides
        self.layout = layout
        self.paperOrientation = paperOrientation
        self.theme = theme
        self.textScale = textScale
        self.preset = preset
        self.options = options
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
}

/// What the renderer adds to the pages of a text and what it reads from the text on the way.
struct FinishedPages {
    var facts: DocumentFacts?
    var contentsPageCount = 0
    var blankPages: Set<Int> = []
    /// Where the note pages go, for pages laid out knowing about them.
    var plan: FinishedPagePlan?
    var notePages: [Int] = []
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
    public var unreadableDocumentURLs: [URL] = []
    public var binderDocuments: [URL: PDFDocument] = [:]
    /// What the text says about itself, for a format that prints with a theme.
    public var facts: DocumentFacts?
    /// What was added to the text's pages.
    public var addedContentsPages = 0
    /// The logical pages that were added as blanks.
    public var blankPages: Set<Int> = []
    /// How many of the logical pages are note pages.
    public var addedNotePages = 0
    let sheetKey: SheetKey
    let options: PrintOptions
}

/// What the composed sheets depend on: the logical pages they were made from and the settings of the imposition.
struct SheetKey: Equatable {
    let logicalID: Int
    let layout: PrintLayout
    let options: PrintOptions
    let orientsEachPage: Bool
    let furniture: PageFurniture.Context
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
    public let facts: DocumentFacts?
    public let addedContentsPages: Int
    public let blankPages: Set<Int>
    public let addedNotePages: Int

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
        facts = prepared.facts
        addedContentsPages = prepared.addedContentsPages
        blankPages = prepared.blankPages
        addedNotePages = prepared.addedNotePages
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
        var binderPageSizes: [CGSize] = []
        var issues: [PrintIssue] = []
        var changeMarks: [ChangeMark] = []
        var markRequests: [MarkdownMarkRequest] = []
        var finishing = FinishedPages()
        /// The serialized pages the sheets are drawn from, made once for all compositions.
        var composingSource: CGPDFDocument?
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
    }

    private struct CacheKey: Equatable {
        let source: DocumentSource
        let pageSize: CGSize
        let mixesImagePages: Bool
        let theme: PrintTheme?
        let textScale: Double?
        let code: CodeStyle?
        let preset: HTMLCleanupPreset?
        let margins: PageMargins
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
            self.paginate = { request in
                try await WebPaginator().paginateWithResult(
                    request.source, pageSize: request.pageSize, margins: request.margins,
                    allowsJavaScript: request.allowsJavaScript, preparationScript: request.preparationScript,
                    readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
                    rendersMermaid: request.rendersMermaid)
            }
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
    }

    /// Prepares the logical pages and composes the printed sheets.
    public func render(_ source: DocumentSource, settings: RenderSettings) async throws -> RenderResult {
        try await composeSheet(for: try await prepare(source, settings: settings))
    }

    /// Prepares the logical pages only. The screen can show them while `composeSheet(for:)` imposes them on paper.
    public func prepare(_ source: DocumentSource, settings: RenderSettings) async throws -> PreparedRender {
        let output = try await prepareOnce(source, settings: settings)
        // HTML in Auto turns with its `@page` rules, which are known only once it has been laid out. A document that
        // asks for landscape is laid out again; the common upright one costs nothing more.
        if source.format == .html, settings.paperOrientation == .auto, settings.layout.kind != .booklet,
            settings.slides == nil, let rule = sourcePageRule, rule.source == source,
            (rule.orientation == .landscape) != (output.resolvedOrientation == .landscape)
        {
            return try await prepareOnce(source, settings: settings)
        }
        return output
    }

    /// Composes the printed sheets of a prepared render, reusing the sheets of a recent render with the same logical
    /// pages and imposition settings.
    public func composeSheet(for prepared: PreparedRender) async throws -> RenderResult {
        try Task.checkCancellation()
        if let index = sheets.firstIndex(where: { $0.key == prepared.sheetKey }) {
            let entry = sheets.remove(at: index)
            sheets.append(entry)
            return RenderResult(prepared, sheet: entry.document, sheetOrientations: entry.orientations)
        }
        do {
            try await willComposeSheet?()
            let composer = PDFComposer()
            let sheet: PDFDocument
            if let logical = cachedLogical(id: prepared.sheetKey.logicalID) {
                if logical.composingSource == nil {
                    logical.composingSource = try? PDFComposer.composingSource(of: logical.document)
                }
                guard let source = logical.composingSource else { throw RenderingError.invalidPDF }
                sheet = try await composer.compose(
                    source, pageCount: logical.document.pageCount, layout: prepared.layout,
                    options: prepared.options, orientsEachPage: prepared.sheetKey.orientsEachPage,
                    furniture: prepared.sheetKey.furniture)
            } else {
                // The cache has moved on to other pages; compose from the document itself.
                sheet = try await composer.compose(
                    prepared.logicalDocument, layout: prepared.layout, options: prepared.options,
                    orientsEachPage: prepared.sheetKey.orientsEachPage, furniture: prepared.sheetKey.furniture)
            }
            try Task.checkCancellation()
            sheetCompositionCount += 1
            let orientations = (0..<sheet.pageCount).compactMap { index -> PaperOrientation? in
                guard let page = sheet.page(at: index) else { return nil }
                let size = page.bounds(for: .mediaBox).size
                return size.width > size.height ? .landscape : .portrait
            }
            sheets.append((prepared.sheetKey, sheet, orientations))
            if sheets.count > Self.sheetCacheLimit { sheets.removeFirst(sheets.count - Self.sheetCacheLimit) }
            return RenderResult(prepared, sheet: sheet, sheetOrientations: orientations)
        } catch {
            throw Self.renderingError(error)
        }
    }

    private func cachedLogical(id: Int) -> Logical? {
        [cache?.logical, cache?.logical.noted?.logical].compactMap { $0 }.first { $0.id == id }
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
        default: return RenderingError.paginationFailed
        }
    }

    private func prepareOnce(_ source: DocumentSource, settings: RenderSettings) async throws -> PreparedRender {
        try Task.checkCancellation()
        generation += 1
        let currentGeneration = generation
        do {
            var settings = settings
            if source.children != nil { settings.notes = NotePages() }
            var landscape: Bool
            if source.children != nil {
                landscape = settings.paperOrientation == .landscape && settings.layout.kind != .booklet
            } else if settings.layout.kind == .booklet {
                landscape = false
            } else if settings.paperOrientation == .auto, source.format == .html, let slides = settings.slides {
                // A slide prints best on paper of its own shape, whatever the deck's `@page` says.
                landscape = slides.slideSize.width > slides.slideSize.height
            } else if settings.paperOrientation == .auto {
                landscape = try await automaticLandscape(source)
            } else {
                landscape = settings.paperOrientation == .landscape
            }
            settings.layout = settings.layout.oriented(landscape)
            let pageSize = settings.layout.logicalPageSize(options: settings.options)
            let margins = settings.layout.logicalMargins(options: settings.options)
            guard settings.options.margins.isValid,
                PDFDrawing.validGeometry(pageSize: pageSize, margins: WebPaginator.Margins(margins))
            else {
                throw RenderingError.invalidMargins
            }
            let isThemed = source.children == nil && source.format.usesPrintTheme
            let isPlainPDF = source.format == .pdf && source.children == nil
            let key = CacheKey(
                source: source, pageSize: isPlainPDF ? .zero : pageSize,
                mixesImagePages: source.format == .image && settings.usesPerPageOrientation
                    && Set(sourcePageSizes?.sizes.map { $0.width > $0.height } ?? []).count > 1,
                theme: source.children != nil || source.format.usesPrintTheme ? settings.theme : nil,
                textScale: source.children != nil || source.format.usesPrintTheme ? settings.textScale : nil,
                code: source.children != nil || source.format.usesPrintTheme ? settings.code : nil,
                preset: source.children != nil || source.format.usesHTMLPreset ? settings.preset : nil,
                margins: isPlainPDF ? .zero : margins,
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
                contentsLanguage: isThemed && settings.finish.toc.mode == .front ? settings.pageLanguage : nil,
                hasNotes: settings.activeNotes != nil,
                textNotes: isThemed
                    ? settings.activeNotes.map {
                        FinishedPagePlan.Notes(placement: $0.placement, layoutKind: settings.layout.kind)
                    } : nil)
            let logical: Logical
            if let cache, cache.key == key {
                logical = cache.logical
            } else {
                var requiredFolderAccess: URL?
                var issues: [PrintIssue] = []
                var binderOutput: BinderOutput?
                var finishing = FinishedPages()
                let document: PDFDocument
                let unreadable: [URL]
                let candidates: [SmartRemovalCandidate]
                if let children = source.children {
                    let output = try await binder(children, settings: settings)
                    binderOutput = output
                    document = output.document
                    unreadable = []
                    candidates = []
                    issues = output.issues
                    requiredFolderAccess = output.requiredFolderAccess
                    finishing.blankPages = output.blankPages
                } else if let images = source.images {
                    (document, unreadable) = try await imageBundle(images, settings: settings)
                    candidates = []
                } else {
                    var outputSettings = settings
                    outputSettings.markdownChanges = []
                    let result = try await logicalDocument(source, settings: outputSettings)
                    if source.format == .html, generation == currentGeneration {
                        sourcePageRule = (source, PageRule.orientation(of: result.pageRules))
                    }
                    requiredFolderAccess = result.requiredFolderAccess
                    issues = result.issues
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
                logical.requiredFolderAccess = requiredFolderAccess
                logical.issues = issues
                logical.unreadableDocuments = binderOutput?.unreadable ?? []
                logical.binderDocuments = binderOutput?.documents ?? [:]
                logical.binderPageSizes = binderOutput?.pageSizes ?? []
                logical.finishing = finishing
                logicalRenderCount += 1
                // An older suspended render must not overwrite the cache of a newer request.
                if generation == currentGeneration { cache = (key, logical) }
            }
            let requests = source.format == .markdown ? settings.markdownChanges : []
            if !requests.isEmpty, logical.markRequests != requests {
                // Geometry comes from a disposable pass; output always uses the anchor-free cached PDF.
                // Structural selectors in a theme can slightly offset these rectangles, never the output.
                let marked = try await logicalDocument(source, settings: settings)
                try Task.checkCancellation()
                logical.changeMarks = ChangeMarkAnchors.extract(from: marked.document, requests: requests)
                logical.markRequests = requests
            }
            if source.children != nil, settings.paperOrientation == .auto, settings.layout.kind != .booklet {
                // Children keep their own logical orientation; only the shared output follows the majority.
                landscape = PaperOrientation.auto.isLandscape(pageSizes: logical.binderPageSizes)
                settings.layout = settings.layout.oriented(landscape)
            }
            let pages = try await noted(logical, source: source, settings: settings)
            try Task.checkCancellation()
            let plan = Imposition.plan(pageCount: pages.document.pageCount, layout: settings.layout)
            return PreparedRender(
                id: currentGeneration, resolvedOrientation: landscape ? .landscape : .portrait, layout: settings.layout,
                logicalDocument: pages.document, viewDocument: pages.viewDocument, plan: plan,
                summary: PrintSummary(plan: plan),
                requiredFolderAccess: pages.requiredFolderAccess, unreadableImageURLs: pages.unreadable,
                smartRemovalCandidates: pages.candidates, issues: pages.issues,
                changeMarks: requests.isEmpty ? [] : logical.changeMarks,
                unreadableDocumentURLs: pages.unreadableDocuments, binderDocuments: pages.binderDocuments,
                facts: pages.finishing.facts, addedContentsPages: pages.finishing.contentsPageCount,
                blankPages: pages.finishing.blankPages, addedNotePages: pages.finishing.notePages.count,
                sheetKey: SheetKey(
                    logicalID: pages.id, layout: settings.layout, options: settings.options,
                    orientsEachPage: settings.usesPerPageOrientation
                        && (source.format == .pdf || source.format == .image),
                    furniture: furnitureContext(source, logical: pages, settings: settings)),
                options: settings.options)
        } catch {
            throw Self.renderingError(error)
        }
    }

    /// The pages with their note pages, or the pages themselves without any. Everything here is drawn, so it stays
    /// quick enough to follow the sheet's sliders; the pages laid out by WebKit come from the cache as they are.
    private func noted(_ logical: Logical, source: DocumentSource, settings: RenderSettings) async throws -> Logical {
        guard let notes = settings.activeNotes else { return logical }
        let pageSize = settings.layout.logicalPageSize(options: settings.options)
        let isPlainPDF = source.format == .pdf
        let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
        let shift =
            !isPlainPDF && settings.layout.mirrorsMargins(options: settings.options) ? margins.right - margins.left : 0
        let key = NotedKey(
            notes: notes, layoutKind: settings.layout.kind, pageSize: pageSize, mirrorShift: shift)
        if let noted = logical.noted, noted.key == key { return noted.logical }
        let plan =
            logical.finishing.plan
            ?? FinishedPagePlan(
                bodyPageCount: logical.document.pageCount, contentsPageCount: 0, rightPageStarts: [],
                notes: .init(
                    placement: notes.placement, layoutKind: settings.layout.kind,
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
                PaperComposer.compose(document, paper: nil, shift: { !notes.contains($0) && $0 % 2 == 1 ? shift : 0 })
                ?? document
        } else {
            output = document
        }
        logicalSerial += 1
        let noted = Logical(
            id: logicalSerial, document: output, viewDocument: output, unreadable: logical.unreadable,
            candidates: logical.candidates)
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
            let pages = DocumentOutline.pages(of: headings, inPageTexts: texts)
            return DocumentOutline.chapterEnds(of: headings, pages: pages, inPageTexts: texts)
        default: return []
        }
    }

    private struct BinderOutput {
        let document = PDFDocument()
        var documents: [URL: PDFDocument] = [:]
        var pageSizes: [CGSize] = []
        var unreadable: [URL] = []
        var issues: [PrintIssue] = []
        var requiredFolderAccess: URL?
        var blankPages: Set<Int> = []
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
                childSettings.markdownChanges = []
                // Left and right belong to the bound pages, which a document on its own does not know.
                childSettings.options.mirrorsMargins = false
                childSettings.notes = NotePages()
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
                        CGRect(origin: .zero, size: settings.layout.logicalPageSize(options: settings.options)),
                        for: .mediaBox)
                    output.blankPages.insert(output.document.pageCount)
                    output.document.insert(blank, at: output.document.pageCount)
                }
                output.pageSizes += Self.pageSizes(of: document)
                for page in pages { output.document.insert(page, at: output.document.pageCount) }
                if let url = child.fileURL { output.documents[url] = document }
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

    private func logicalDocument(_ source: DocumentSource, settings: RenderSettings) async throws -> WebPaginator.Result
    {
        switch source.format {
        case .zipArchive:
            throw RenderingError.unsupportedFormat
        case .pdf:
            guard let document = PDFDocument(data: source.data) else { throw RenderingError.invalidPDF }
            guard !document.isEncrypted && !document.isLocked else { throw RenderingError.encryptedPDF }
            guard document.pageCount > 0 else { throw RenderingError.invalidPDF }
            return WebPaginator.Result(document: document)
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
                input = .sandboxed(try Self.decodedText(source.data), access: access)
            } else if let url = source.fileURL {
                input = .file(url, readAccessURL: url.deletingLastPathComponent())
            } else {
                input = .html(try Self.decodedText(source.data), baseURL: nil)
            }
            var preparation =
                (settings.opensDetails ? HTMLSnapshotScript.openDetailsJavaScript + "\n" : "")
                + HTMLCleanupScript.javaScript(for: settings.preset)
            if let slides = settings.slides {
                let pageSize = settings.layout.logicalPageSize(options: settings.options)
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
                    pageSize: settings.layout.logicalPageSize(options: settings.options),
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
        case .markdown, .org, .plainText, .csv, .latex:
            var missingImage = false
            let access = resourceAccess(for: source)
            let fragment: HTMLFragment
            if source.format == .markdown, !settings.markdownChanges.isEmpty {
                fragment =
                    MarkdownConverter.convertWithSourceMap(
                        try Self.decodedText(source.data), pageBreakLine: settings.finish.breaks.customLine
                    ).fragment
            } else {
                guard
                    let themed = try Self.themedFragment(
                        source, pageBreakLine: settings.finish.breaks.customLine,
                        imageExists: { url in
                            if let access, !access.permits(url) {
                                missingImage = true
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
                                    missingImage = true
                                }
                                return false
                            }
                        })
                else { throw RenderingError.unsupportedFormat }
                fragment = themed
            }
            let directory = source.fileURL?.deletingLastPathComponent()
            // Without clear pages the paper stays on the text pages, which WebKit draws inside the margins only.
            let separatesPaper = WebPaginator.drawsClearPages
            let html = HTMLDocumentBuilder.build(
                fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
                textScale: settings.textScale, removesPaper: separatesPaper, finish: settings.finish.styleSheet,
                code: settings.code)
            let pageSize = settings.layout.logicalPageSize(options: settings.options)
            let margins = settings.layout.logicalMargins(options: settings.options)
            let marksScript = source.format == .markdown ? ChangeMarkAnchors.javaScript(settings.markdownChanges) : ""
            let themeScript = separatesPaper ? Self.themedPreparation(settings.theme) : settings.theme.script ?? ""
            let codeScript =
                CodeFitScript.javaScript(for: settings.code, pixelsPerPoint: WebPaginator.printPixelsPerPoint) ?? ""
            // The theme's part goes last: its answer whether the theme has paper is the result of the whole.
            let parts = [marksScript, codeScript, themeScript].filter { !$0.isEmpty }
            let preparation: String? = parts.isEmpty ? nil : parts.joined(separator: "\n")
            var text = try await paginateCheckingIssues(
                PaginationRequest(
                    source: sandboxSource(.html(html, baseURL: directory), for: source), pageSize: pageSize,
                    margins: WebPaginator.Margins(margins),
                    allowsJavaScript: false,
                    preparationScript: preparation,
                    readsPageRules: false, drawsBackground: !separatesPaper,
                    rendersMermaid: (source.format == .markdown || source.format == .org)
                        && fragment.body.contains("class=\"mermaid-block\"")), source: source)
            if missingImage { text.requiredFolderAccess = directory }
            text = try await finished(text, fragment: fragment, source: source, settings: settings)
            guard separatesPaper, text.preparationResult == "paper" else { return text }
            let paperHTML = PaperBackground.document(
                theme: settings.theme, format: source.format, baseURL: directory, textScale: settings.textScale,
                pageSize: pageSize, margins: margins, pixelsPerPoint: WebPaginator.printPixelsPerPoint)
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
            result.finishing = text.finishing
            return result
        }
    }

    /// The pages of a text with what the print finish adds to them: the contents in front, a blank before a chapter
    /// that would fall on a left-hand page, and the margins of the left-hand pages turned the other way round.
    private func finished(
        _ text: WebPaginator.Result, fragment: HTMLFragment, source: DocumentSource, settings: RenderSettings
    ) async throws -> WebPaginator.Result {
        var result = text
        let facts = DocumentFacts(fragment: fragment)
        result.finishing.facts = facts
        let finish = settings.finish
        let usesRightPages = settings.layout.hasFacingPages && finish.breaks.usesRightPages
        let wantsContents = finish.toc.mode == .front && !facts.headings.isEmpty
        let notes = settings.activeNotes
        guard usesRightPages || wantsContents || settings.mirrorsLaidOutPages || notes != nil else { return result }
        let pageCount = text.document.pageCount
        var plan = FinishedPagePlan(bodyPageCount: pageCount, contentsPageCount: 0, rightPageStarts: [])
        var contents: PDFDocument?
        if usesRightPages || wantsContents || notes != nil {
            let showsSourceContents = finish.toc.mode == .source || finish.toc.keepsSourceTOC
            let pageTexts = (0..<pageCount).map { text.document.page(at: $0)?.string ?? "" }
            let headingPages = DocumentOutline.pages(
                of: facts.headings, inPageTexts: pageTexts,
                contentsEntries: showsSourceContents ? DocumentOutline.sourceContentsEntries(inHTML: fragment.body) : []
            )
            let insertion = notes.map {
                FinishedPagePlan.Notes(
                    placement: $0.placement, layoutKind: settings.layout.kind,
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
        var finished = WebPaginator.Result(
            document: Self.mirroringMargins(of: document, settings: settings),
            preparationResult: text.preparationResult, pageRules: text.pageRules,
            requiredFolderAccess: text.requiredFolderAccess)
        finished.issues = text.issues.map { issue in
            var issue = issue
            issue.pageNumber = issue.pageNumber.flatMap { number in
                plan.bodyPageIndices.indices.contains(number - 1) ? plan.bodyPageIndices[number - 1] + 1 : number
            }
            return issue
        }
        finished.finishing = FinishedPages(
            facts: facts, contentsPageCount: contents?.pageCount ?? 0, blankPages: plan.blankPages,
            plan: notes != nil ? plan : nil)
        return finished
    }

    private static let contentsLayoutLimit = 3

    /// The contents laid out like the text: the same theme, paper size and margins.
    private func contentsPages(
        _ entries: [PaperContents.Entry], source: DocumentSource, settings: RenderSettings
    ) async throws -> PDFDocument {
        let directory = source.fileURL?.deletingLastPathComponent()
        let separatesPaper = WebPaginator.drawsClearPages
        let fragment = PaperContents.fragment(
            entries: entries, look: settings.finish.toc.look,
            title: PaperContents.title(language: settings.pageLanguage))
        let html = HTMLDocumentBuilder.build(
            fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
            textScale: settings.textScale, removesPaper: separatesPaper)
        let script = separatesPaper ? Self.themedPreparation(settings.theme) : settings.theme.script
        return try await paginate(
            PaginationRequest(
                source: sandboxSource(.html(html, baseURL: directory), for: source),
                pageSize: settings.layout.logicalPageSize(options: settings.options),
                margins: WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options)),
                allowsJavaScript: false, preparationScript: script?.isEmpty == false ? script : nil,
                readsPageRules: false, drawsBackground: !separatesPaper)
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
                    CGRect(origin: .zero, size: settings.layout.logicalPageSize(options: settings.options)),
                    for: .mediaBox)
                body.insert(blank, at: index)
            }
            index += 1
        }
        return body
    }

    /// Moves the content of the even pages, which are left-hand pages, so that the side of the binding keeps its
    /// margin. The pages were laid out with the same width, so moving them is all it takes.
    private static func mirroringMargins(of document: PDFDocument, settings: RenderSettings) -> PDFDocument {
        guard settings.mirrorsLaidOutPages else { return document }
        let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
        let shift = margins.right - margins.left
        guard shift != 0, document.pageCount > 1 else { return document }
        return PaperComposer.compose(document, paper: nil, shift: { $0 % 2 == 1 ? shift : 0 }) ?? document
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
        return PageFurniture.Context(
            fileName: fileName, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
            date: furniture.dateText(now(), language: settings.pageLanguage),
            blankPages: logical.finishing.blankPages.union(logical.finishing.notePages))
    }

    private func paginateCheckingIssues(_ request: PaginationRequest, source: DocumentSource) async throws
        -> WebPaginator.Result
    {
        let wrapped = PaginationRequest(
            source: request.source, pageSize: request.pageSize, margins: request.margins,
            allowsJavaScript: request.allowsJavaScript,
            preparationScript: PrintIssueAnchors.following(
                request.preparationScript, themed: source.format.usesPrintTheme),
            readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
            rendersMermaid: request.rendersMermaid)
        let output = try await paginate(wrapped)
        let preparation = output.preparationResult.flatMap {
            try? JSONDecoder().decode(PrintIssueAnchors.Preparation.self, from: Data($0.utf8))
        }
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
            document: output.document,
            preparationResult: preparation.map { $0.previous } ?? output.preparationResult,
            pageRules: output.pageRules, requiredFolderAccess: output.requiredFolderAccess)
        result.issues = PrintIssueAnchors.extract(from: output.document, issues: issues)
        return result
    }

    private func resourceAccess(for source: DocumentSource) -> LocalResourceAccess? {
        guard isSandboxed(), let file = source.fileURL else { return nil }
        return LocalResourceAccess(documentURL: file, folders: source.allowedResourceFolders)
    }

    private func sandboxSource(_ input: WebPaginator.Source, for source: DocumentSource) -> WebPaginator.Source {
        guard let access = resourceAccess(for: source) else { return input }
        switch input {
        case .html(let html, let base):
            return .sandboxed(base.map { WebPaginator.injectingBase($0, into: html) } ?? html, access: access)
        case .file:
            return .sandboxed(nil, access: access)
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
    public nonisolated static func structureHTML(of source: DocumentSource) -> String? {
        if source.format == .html { return TextDecoding.decode(source.data).text }
        return (try? themedFragment(source))??.body
    }

    /// The HTML of a format that prints with a theme, or nil for the formats that print as they are.
    nonisolated static func themedFragment(
        _ source: DocumentSource, pageBreakLine: String = "",
        imageExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> HTMLFragment? {
        switch source.format {
        case .markdown: MarkdownConverter.convert(try decodedText(source.data), pageBreakLine: pageBreakLine)
        case .latex:
            LaTeXConverter.convert(
                try decodedText(source.data), directory: source.fileURL?.deletingLastPathComponent(),
                imageExists: imageExists)
        case .org: OrgConverter.convert(try decodedText(source.data))
        case .plainText: PlainTextConverter.convert(try decodedText(source.data))
        case .csv:
            CSVConverter.convert(
                try decodedText(source.data),
                delimiter: source.fileURL?.pathExtension.lowercased() == "tsv" ? "\t" : ",")
        default: nil
        }
    }

    private nonisolated static func decodedText(_ data: Data) throws -> String {
        let decoded = TextDecoding.decode(data)
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
