import Foundation
import PDFKit
import SurimonoCore

public struct DocumentSource: Equatable, Sendable {
    public let data: Data
    public let fileURL: URL?
    public let format: DocumentFormat
    public let images: [Image]?
    /// The HTML is a copy of a live page's current state rather than the file's bytes; its own scripts already ran.
    public let isLiveSnapshot: Bool

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
        isLiveSnapshot = false
    }

    public init(data: Data, fileURL: URL? = nil, format: DocumentFormat) {
        self.init(data: data, fileURL: fileURL, format: format, isLiveSnapshot: false)
    }

    private init(data: Data, fileURL: URL?, format: DocumentFormat, isLiveSnapshot: Bool) {
        self.data = data
        self.fileURL = fileURL
        self.format = format
        images = nil
        self.isLiveSnapshot = isLiveSnapshot
    }

    /// Whether the page's own JavaScript runs while it is laid out.
    func allowsJavaScript(_ settings: RenderSettings) -> Bool {
        format == .html && !isLiveSnapshot && settings.allowsJavaScriptInHTML && !settings.preset.disablesJavaScript
    }
}

public struct RenderSettings: Equatable, Sendable {
    public var paperOrientation: PaperOrientation
    public var layout: PrintLayout
    public var theme: PrintTheme
    public var textScale: Double
    public var preset: HTMLCleanupPreset
    public var options: PrintOptions
    public var allowsJavaScriptInHTML: Bool
    public var smartRemoval: SmartRemovalRequest?
    /// HTML: open every `<details>` of the copy being laid out.
    public var opensDetails: Bool
    /// HTML that is a slide deck: print its slides one to a page, landscape in Auto.
    public var slides: SlidePrintRequest?

    var usesPerPageOrientation: Bool {
        layout.kind == .normal && layout.duplex == .none && paperOrientation == .auto
    }

    public init(
        layout: PrintLayout, theme: PrintTheme, preset: HTMLCleanupPreset,
        options: PrintOptions = PrintOptions(), allowsJavaScriptInHTML: Bool = false,
        smartRemoval: SmartRemovalRequest? = nil, textScale: Double = 1, paperOrientation: PaperOrientation = .auto,
        opensDetails: Bool = false, slides: SlidePrintRequest? = nil
    ) {
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
}

@MainActor
public struct RenderResult {
    // Content orientation is retained separately because 2-up reverses the sheet orientation.
    public let resolvedOrientation: PaperOrientation
    // The uniform-layout fallback; mixed output must use sheetOrientations instead.
    public var sheetOrientation: PaperOrientation {
        layout.sheetSize.width > layout.sheetSize.height ? .landscape : .portrait
    }
    /// Indexed by sheetDocument page (a printed side), including any imposed blank back.
    public var sheetOrientations: [PaperOrientation] {
        (0..<sheetDocument.pageCount).compactMap { index in
            guard let page = sheetDocument.page(at: index) else { return nil }
            let size = page.bounds(for: .mediaBox).size
            return size.width > size.height ? .landscape : .portrait
        }
    }
    public var hasMixedSheetOrientations: Bool { Set(sheetOrientations).count > 1 }
    public let layout: PrintLayout
    public let logicalDocument: PDFDocument
    public let sheetDocument: PDFDocument
    public let plan: ImpositionPlan
    public let summary: PrintSummary
    public let unreadableImageURLs: [URL]
    public let smartRemovalCandidates: [SmartRemovalCandidate]
}

/// Keep one renderer per open document and cancel the previous caller Task before starting a new render.
@MainActor
public final class DocumentRenderer {
    public enum RenderingError: Error, Equatable {
        case noReadableImages([URL])
        /// An image's content no longer matches the hash it was identified by; hash the images again and retry.
        case imageChanged(URL)
        case unsupportedFormat
        case textDecodingFailed
        case invalidPDF
        case encryptedPDF
        case invalidMargins
        case pagination(WebPaginator.PaginationError)
        case paginationFailed
        case image(ImagePageRenderer.RenderingError)
        case composition(PDFComposer.CompositionError)
    }

    public typealias Paginate = @MainActor (PaginationRequest) async throws -> PDFDocument
    public typealias PaginateWithResult = @MainActor (PaginationRequest) async throws -> WebPaginator.Result

    public private(set) var logicalRenderCount = 0
    private let paginate: PaginateWithResult
    private var cache: (key: CacheKey, data: Data, unreadable: [URL], candidates: [SmartRemovalCandidate])?
    private var generation = 0
    private var sourcePageSizes: (source: DocumentSource, sizes: [CGSize])?
    /// The orientation the `@page` rules of an HTML source ask for, known once the source has been laid out.
    private var sourcePageRule: (source: DocumentSource, orientation: PaperOrientation?)?

    private struct CacheKey: Equatable {
        let source: DocumentSource
        let pageSize: CGSize
        let mixesImagePages: Bool
        let theme: PrintTheme?
        let textScale: Double?
        let preset: HTMLCleanupPreset?
        let margin: Double
        let allowsJavaScript: Bool
        let smartRemoval: SmartRemovalRequest?
        let opensDetails: Bool
        let slides: SlidePrintRequest?
    }

    public init(paginate: Paginate? = nil) {
        if let paginate {
            self.paginate = { request in WebPaginator.Result(document: try await paginate(request)) }
        } else {
            self.paginate = { request in
                try await WebPaginator().paginateWithResult(
                    request.source, pageSize: request.pageSize, margins: request.margins,
                    allowsJavaScript: request.allowsJavaScript, preparationScript: request.preparationScript,
                    readsPageRules: request.readsPageRules)
            }
        }
    }

    public init(paginateWithResult: @escaping PaginateWithResult) {
        self.paginate = paginateWithResult
    }

    /// Invalidate after external images, fonts, or an HTML file change without a change to source.data.
    public func clearCache() {
        generation += 1
        cache = nil
        sourcePageSizes = nil
        sourcePageRule = nil
    }

    public func render(_ source: DocumentSource, settings: RenderSettings) async throws -> RenderResult {
        let output = try await renderOnce(source, settings: settings)
        // HTML in Auto turns with its `@page` rules, which are known only once it has been laid out. A document that
        // asks for landscape is laid out again; the common upright one costs nothing more.
        if source.format == .html, settings.paperOrientation == .auto, settings.layout.kind != .booklet,
            settings.slides == nil, let rule = sourcePageRule, rule.source == source,
            (rule.orientation == .landscape) != (output.resolvedOrientation == .landscape)
        {
            return try await renderOnce(source, settings: settings)
        }
        return output
    }

    private func renderOnce(_ source: DocumentSource, settings: RenderSettings) async throws -> RenderResult {
        try Task.checkCancellation()
        generation += 1
        let currentGeneration = generation
        do {
            var settings = settings
            let landscape: Bool
            if settings.layout.kind == .booklet {
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
            let margin = settings.layout.logicalMarginsInMillimeters(options: settings.options)
            guard settings.options.marginsInMillimeters.isFinite, settings.options.marginsInMillimeters >= 0,
                PDFDrawing.validGeometry(pageSize: pageSize, margin: margin * 72 / 25.4)
            else {
                throw RenderingError.invalidMargins
            }
            let key = CacheKey(
                source: source, pageSize: source.format == .pdf ? .zero : pageSize,
                mixesImagePages: source.format == .image && settings.usesPerPageOrientation
                    && Set(sourcePageSizes?.sizes.map { $0.width > $0.height } ?? []).count > 1,
                theme: source.format.usesPrintTheme ? settings.theme : nil,
                textScale: source.format.usesPrintTheme ? settings.textScale : nil,
                preset: source.format.usesHTMLPreset ? settings.preset : nil,
                margin: source.format == .pdf ? 0 : margin,
                allowsJavaScript: source.allowsJavaScript(settings),
                smartRemoval: source.format == .html ? settings.smartRemoval : nil,
                opensDetails: source.format == .html && settings.opensDetails,
                slides: source.format == .html ? settings.slides : nil)
            let logical: PDFDocument
            let cachedData: Data
            let reused: Bool
            let unreadable: [URL]
            let candidates: [SmartRemovalCandidate]
            if let cache, cache.key == key, let document = PDFDocument(data: cache.data) {
                logical = document
                cachedData = cache.data
                unreadable = cache.unreadable
                candidates = cache.candidates
                reused = true
            } else {
                if let images = source.images {
                    (logical, unreadable) = try await imageBundle(images, settings: settings)
                    candidates = []
                } else {
                    let result = try await logicalDocument(source, settings: settings)
                    if source.format == .html, generation == currentGeneration {
                        sourcePageRule = (source, PageRule.orientation(of: result.pageRules))
                    }
                    logical = result.document
                    candidates =
                        source.format == .html && settings.smartRemoval != nil
                        ? SmartRemovalScript.candidates(fromJSON: result.preparationResult ?? "") : []
                    unreadable = []
                }
                try Task.checkCancellation()
                guard logical.pageCount > 0, let data = logical.dataRepresentation() else {
                    throw RenderingError.invalidPDF
                }
                cachedData = data
                reused = false
            }
            let sheet = try await PDFComposer().compose(
                logical, layout: settings.layout, options: settings.options,
                orientsEachPage: settings.usesPerPageOrientation && (source.format == .pdf || source.format == .image))
            try Task.checkCancellation()
            if !reused {
                logicalRenderCount += 1
                // An older suspended render must not overwrite the cache of a newer request.
                if generation == currentGeneration { cache = (key, cachedData, unreadable, candidates) }
            }
            let plan = Imposition.plan(pageCount: logical.pageCount, layout: settings.layout)
            return RenderResult(
                resolvedOrientation: landscape ? .landscape : .portrait, layout: settings.layout,
                logicalDocument: logical, sheetDocument: sheet, plan: plan, summary: PrintSummary(plan: plan),
                unreadableImageURLs: unreadable, smartRemovalCandidates: candidates)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            switch error {
            case let error as RenderingError: throw error
            case let error as WebPaginator.PaginationError: throw RenderingError.pagination(error)
            case let error as ImagePageRenderer.RenderingError: throw RenderingError.image(error)
            case let error as PDFComposer.CompositionError: throw RenderingError.composition(error)
            default: throw RenderingError.paginationFailed
            }
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
            sizes = (0..<document.pageCount).compactMap { index in
                guard let page = document.page(at: index), let ref = page.pageRef else { return nil }
                let size = ref.getBoxRect(.cropBox).intersection(ref.getBoxRect(.mediaBox)).size
                return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
            }
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
                    marginsInMillimeters: settings.layout.logicalMarginsInMillimeters(options: settings.options),
                    autoRotatesPage: settings.usesPerPageOrientation)
                guard let page = rendered.page(at: 0) else { throw ImagePageRenderer.RenderingError.invalidImage }
                document.insert(page, at: document.pageCount)
            } catch ImagePageRenderer.RenderingError.invalidImage {
                unreadable.append(image.fileURL)
            }
        }
        guard document.pageCount > 0 else { throw RenderingError.noReadableImages(unreadable) }
        return (document, unreadable)
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
                    marginsInMillimeters: settings.layout.logicalMarginsInMillimeters(options: settings.options),
                    autoRotatesPage: settings.usesPerPageOrientation))
        case .html:
            let input: WebPaginator.Source
            if source.isLiveSnapshot {
                let html = String(decoding: source.data, as: UTF8.self)
                input =
                    source.fileURL.map { .snapshot(html, directory: $0.deletingLastPathComponent()) }
                    ?? .html(html, baseURL: nil)
            } else if let url = source.fileURL {
                input = .file(url, readAccessURL: url.deletingLastPathComponent())
            } else {
                input = .html(try decodedText(source.data), baseURL: nil)
            }
            var preparation =
                (settings.opensDetails ? HTMLSnapshotScript.openDetailsJavaScript + "\n" : "")
                + HTMLCleanupScript.javaScript(for: settings.preset)
            if let slides = settings.slides {
                let pageSize = settings.layout.logicalPageSize(options: settings.options)
                let margin = settings.layout.logicalMarginsInMillimeters(options: settings.options) * 72 / 25.4
                // The paginating web view lays out one CSS pixel to a point.
                let printable = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
                preparation += "\n" + SlideDeckScript.printJavaScript(slides, printableSize: printable)
            }
            if let smartRemoval = settings.smartRemoval {
                preparation += "\n" + PaperCleanupScript.following(SmartRemovalScript.javaScript(for: smartRemoval))
            } else {
                preparation += "\n" + PaperCleanupScript.javaScript
            }
            return try await paginate(
                PaginationRequest(
                    source: input, pageSize: settings.layout.logicalPageSize(options: settings.options),
                    margins: .uniform(
                        millimeters: settings.layout.logicalMarginsInMillimeters(options: settings.options)),
                    allowsJavaScript: source.allowsJavaScript(settings), preparationScript: preparation,
                    readsPageRules: true))
        case .markdown, .org, .plainText, .csv:
            let text = try decodedText(source.data)
            let fragment: HTMLFragment
            switch source.format {
            case .markdown: fragment = MarkdownConverter.convert(text)
            case .org: fragment = OrgConverter.convert(text)
            case .plainText: fragment = PlainTextConverter.convert(text)
            case .csv:
                fragment = CSVConverter.convert(
                    text, delimiter: source.fileURL?.pathExtension.lowercased() == "tsv" ? "\t" : ",")
            default: throw RenderingError.unsupportedFormat
            }
            let directory = source.fileURL?.deletingLastPathComponent()
            let html = HTMLDocumentBuilder.build(
                fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory,
                textScale: settings.textScale)
            return try await paginate(
                PaginationRequest(
                    source: .html(html, baseURL: directory),
                    pageSize: settings.layout.logicalPageSize(options: settings.options),
                    margins: .uniform(
                        millimeters: settings.layout.logicalMarginsInMillimeters(options: settings.options)),
                    allowsJavaScript: false, preparationScript: nil, readsPageRules: false))
        }
    }

    private func decodedText(_ data: Data) throws -> String {
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
