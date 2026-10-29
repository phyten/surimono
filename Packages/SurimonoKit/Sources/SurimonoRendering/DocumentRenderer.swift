import Foundation
import PDFKit
import SurimonoCore

public struct DocumentSource: Equatable, Sendable {
    public let data: Data
    public let fileURL: URL?
    public let format: DocumentFormat
    public let images: [Image]?

    public struct Image: Equatable, Sendable {
        public let data: Data
        public let fileURL: URL

        public init(data: Data, fileURL: URL) {
            self.data = data
            self.fileURL = fileURL
        }
    }

    public static func images(_ images: [Image]) -> Self { Self(images: images) }

    private init(images: [Image]) {
        data = Data()
        fileURL = nil
        format = .image
        self.images = images
    }

    public init(data: Data, fileURL: URL? = nil, format: DocumentFormat) {
        self.data = data
        self.fileURL = fileURL
        self.format = format
        images = nil
    }
}

public struct RenderSettings: Equatable, Sendable {
    public var layout: PrintLayout
    public var theme: PrintTheme
    public var preset: HTMLCleanupPreset
    public var options: PrintOptions
    public var allowsJavaScriptInHTML: Bool

    public init(
        layout: PrintLayout, theme: PrintTheme, preset: HTMLCleanupPreset,
        options: PrintOptions = PrintOptions(), allowsJavaScriptInHTML: Bool = false
    ) {
        self.layout = layout
        self.theme = theme
        self.preset = preset
        self.options = options
        self.allowsJavaScriptInHTML = allowsJavaScriptInHTML
    }
}

public struct PaginationRequest: Sendable {
    public let source: WebPaginator.Source
    public let pageSize: CGSize
    public let margins: WebPaginator.Margins
    public let allowsJavaScript: Bool
    public let preparationScript: String?
}

@MainActor
public struct RenderResult {
    public let logicalDocument: PDFDocument
    public let sheetDocument: PDFDocument
    public let plan: ImpositionPlan
    public let summary: PrintSummary
    public let unreadableImageURLs: [URL]
}

/// Keep one renderer per open document and cancel the previous caller Task before starting a new render.
@MainActor
public final class DocumentRenderer {
    public enum RenderingError: Error, Equatable {
        case noReadableImages([URL])
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

    public private(set) var logicalRenderCount = 0
    private let paginate: Paginate
    private var cache: (key: CacheKey, data: Data, unreadable: [URL])?
    private var generation = 0

    private struct CacheKey: Equatable {
        let source: DocumentSource
        let pageSize: CGSize
        let theme: PrintTheme?
        let preset: HTMLCleanupPreset?
        let margin: Double
        let allowsJavaScript: Bool
    }

    public init(paginate: Paginate? = nil) {
        self.paginate =
            paginate ?? { request in
                try await WebPaginator().paginate(
                    request.source, pageSize: request.pageSize, margins: request.margins,
                    allowsJavaScript: request.allowsJavaScript, preparationScript: request.preparationScript)
            }
    }

    /// Invalidate after external images, fonts, or an HTML file change without a change to source.data.
    public func clearCache() {
        generation += 1
        cache = nil
    }

    public func render(_ source: DocumentSource, settings: RenderSettings) async throws -> RenderResult {
        try Task.checkCancellation()
        generation += 1
        let currentGeneration = generation
        let pageSize = settings.layout.logicalPageSize
        let margin = settings.options.marginsInMillimeters
        guard PDFDrawing.validGeometry(pageSize: pageSize, margin: margin * 72 / 25.4) else {
            throw RenderingError.invalidMargins
        }
        let key = CacheKey(
            source: source, pageSize: pageSize,
            theme: source.format.usesPrintTheme ? settings.theme : nil,
            preset: source.format.usesHTMLPreset ? settings.preset : nil,
            margin: margin,
            allowsJavaScript: source.format == .html && settings.allowsJavaScriptInHTML
                && !settings.preset.disablesJavaScript)
        do {
            let logical: PDFDocument
            let cachedData: Data
            let reused: Bool
            let unreadable: [URL]
            if let cache, cache.key == key, let document = PDFDocument(data: cache.data) {
                logical = document
                cachedData = cache.data
                unreadable = cache.unreadable
                reused = true
            } else {
                if let images = source.images {
                    (logical, unreadable) = try await imageBundle(images, settings: settings)
                } else {
                    logical = try await logicalDocument(source, settings: settings)
                    unreadable = []
                }
                try Task.checkCancellation()
                guard logical.pageCount > 0, let data = logical.dataRepresentation() else {
                    throw RenderingError.invalidPDF
                }
                cachedData = data
                reused = false
            }
            let sheet = try await PDFComposer().compose(logical, layout: settings.layout, options: settings.options)
            try Task.checkCancellation()
            if !reused {
                logicalRenderCount += 1
                // An older suspended render must not overwrite the cache of a newer request.
                if generation == currentGeneration { cache = (key, cachedData, unreadable) }
            }
            let plan = Imposition.plan(pageCount: logical.pageCount, layout: settings.layout)
            return RenderResult(
                logicalDocument: logical, sheetDocument: sheet, plan: plan, summary: PrintSummary(plan: plan),
                unreadableImageURLs: unreadable)
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

    private func imageBundle(_ images: [DocumentSource.Image], settings: RenderSettings) async throws
        -> (PDFDocument, [URL])
    {
        let document = PDFDocument()
        var unreadable: [URL] = []
        for image in images {
            try Task.checkCancellation()
            do {
                let rendered = try await ImagePageRenderer().render(
                    image.data, pageSize: settings.layout.logicalPageSize,
                    marginsInMillimeters: settings.options.marginsInMillimeters)
                guard let page = rendered.page(at: 0) else { throw ImagePageRenderer.RenderingError.invalidImage }
                document.insert(page, at: document.pageCount)
            } catch ImagePageRenderer.RenderingError.invalidImage {
                unreadable.append(image.fileURL)
            }
        }
        guard document.pageCount > 0 else { throw RenderingError.noReadableImages(unreadable) }
        return (document, unreadable)
    }

    private func logicalDocument(_ source: DocumentSource, settings: RenderSettings) async throws -> PDFDocument {
        switch source.format {
        case .zipArchive:
            throw RenderingError.unsupportedFormat
        case .pdf:
            guard let document = PDFDocument(data: source.data) else { throw RenderingError.invalidPDF }
            guard !document.isEncrypted && !document.isLocked else { throw RenderingError.encryptedPDF }
            guard document.pageCount > 0 else { throw RenderingError.invalidPDF }
            return document
        case .image:
            return try await ImagePageRenderer().render(
                source.data, pageSize: settings.layout.logicalPageSize,
                marginsInMillimeters: settings.options.marginsInMillimeters)
        case .html:
            let input: WebPaginator.Source
            if let url = source.fileURL {
                input = .file(url, readAccessURL: url.deletingLastPathComponent())
            } else {
                input = .html(try decodedText(source.data), baseURL: nil)
            }
            return try await paginate(
                PaginationRequest(
                    source: input, pageSize: settings.layout.logicalPageSize,
                    margins: .uniform(millimeters: settings.options.marginsInMillimeters),
                    allowsJavaScript: settings.allowsJavaScriptInHTML && !settings.preset.disablesJavaScript,
                    preparationScript: HTMLCleanupScript.javaScript(for: settings.preset)))
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
                fragment: fragment, format: source.format, theme: settings.theme, baseURL: directory)
            return try await paginate(
                PaginationRequest(
                    source: .html(html, baseURL: directory), pageSize: settings.layout.logicalPageSize,
                    margins: .uniform(millimeters: settings.options.marginsInMillimeters),
                    allowsJavaScript: false, preparationScript: nil))
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
