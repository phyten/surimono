import Darwin
import Foundation
import UniformTypeIdentifiers

/// The complete offline payload of one data-based Quick Look reply.
public struct FinderPreview: Sendable {
    public struct Attachment: Sendable {
        public let data: Data
        public let type: UTType
    }

    public let html: String
    public let attachments: [String: Attachment]

    private static let policy = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; img-src cid: data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'">
        """
    private static let screenCSS = """
        img { max-width: min(100%, \(PreviewImages.maximumSide)px) !important; max-height: \(PreviewImages.maximumSide)px !important; }
        .preview-missing-image { display: inline-block; width: 1.1em; height: .85em; border: 1px solid #aaa; }
        body { box-sizing: border-box; max-width: 56rem; margin-inline: auto; padding: clamp(16px, 4vw, 40px); }
        """
    private static let theme: PrintTheme? = {
        guard let common = try? String(contentsOf: CoreResources.url("common", extension: "css"), encoding: .utf8),
            let standard = try? String(contentsOf: CoreResources.url("standard", extension: "css"), encoding: .utf8)
        else { return nil }
        // Only the two shipped stylesheets enter this transformation.
        let css = (common + "\n" + standard).replacingOccurrences(
            of: #"(?:page-)?break-(?:inside|after|before)\s*:[^;{}]+;|(?:widows|orphans)\s*:\s*\d+;"#,
            with: "", options: .regularExpression)
        return PrintTheme(id: "standard", name: "Standard", css: css, isBuiltIn: true)
    }()

    enum Failure: Error {
        case oversizedReply
        case complexity
        case encoding
        case unsupported
    }

    // Leave room for the bounded math output, the body and embedded fonts in one data reply.
    static let maximumHTMLBytes = 16 << 20
    static let timeoutMilliseconds = 5_000

    public static func make(for url: URL, bundle: Bundle = .main) -> Self {
        make(for: url, bundle: bundle, deadline: .now + .milliseconds(timeoutMilliseconds))
    }

    static func make(for url: URL, bundle: Bundle = .main, deadline: ContinuousClock.Instant) -> Self {
        make(for: url, bundle: bundle, deadline: deadline, convert: nativeFragment)
    }

    typealias Converter = (String, DocumentFormat, URL) throws -> HTMLFragment

    static func make(
        for url: URL, bundle: Bundle = .main, deadline: ContinuousClock.Instant,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, allowsImages: Bool = true, convert: Converter
    ) -> Self {
        do {
            return try PreviewConversion.$current.withValue(PreviewConversion(deadline: deadline, now: now)) {
                try PreviewConversion.check()
                let format =
                    DocumentFormat(fileExtension: url.pathExtension)
                    ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType).flatMap(
                        DocumentFormat.init(contentType:))
                guard let format,
                    [.markdown, .org, .rst, .latex, .notebook, .quarto, .rMarkdown, .mediawiki].contains(format)
                else {
                    throw Failure.unsupported
                }
                let limit = DocumentSizeLimits.textBytes
                let descriptor = try ConfinedFile.open(url)
                defer { Darwin.close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                    throw CocoaError(.fileReadUnknown)
                }
                let sourceBytes = Int(info.st_size)
                guard sourceBytes <= limit else { throw CocoaError(.fileReadTooLarge) }
                let data = try ConfinedFile.readBytes(descriptor, size: sourceBytes, maximumSize: limit)
                return try build(data, format: format, url: url, allowsImages: allowsImages, convert: convert)
            }
        } catch {
            func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
            let message: String
            switch error {
            case _ where now() >= deadline: return tooComplex(bundle)
            case Failure.oversizedReply: return tooComplex(bundle)
            case Failure.encoding: message = localized("The text encoding could not be read without data loss.")
            case Failure.unsupported: message = localized("This document format is not supported.")
            case CocoaError.fileReadTooLarge: message = localized("This file is too large to preview.")
            case Failure.complexity: message = localized("This document exceeds the preview size limits.")
            default: message = localized("The document could not be loaded.")
            }
            return errorPage(message)
        }
    }

    static func tooComplex(_ bundle: Bundle) -> Self {
        errorPage(bundle.localizedString(forKey: "This document is too complex to preview.", value: nil, table: nil))
    }

    func boundedReply(bundle: Bundle) -> Self {
        html.utf8.count <= Self.maximumHTMLBytes ? self : Self.tooComplex(bundle)
    }

    static func errorPage(_ message: String) -> Self {
        Self(
            html:
                "<!doctype html><html><head><meta charset=\"utf-8\">\(policy)</head><body><p>\(HTML.escape(message))</p></body></html>",
            attachments: [:])
    }

    private static func build(_ data: Data, format: DocumentFormat, url: URL, allowsImages: Bool, convert: Converter)
        throws -> Self
    {
        try PreviewConversion.check()
        guard let text = TextDecoding.losslessText(data) else { throw Failure.encoding }
        var lineCount = 1
        for (i, byte) in text.utf8.enumerated() {
            if i.isMultiple(of: 4096) { try PreviewConversion.check() }
            if byte == 10 { lineCount += 1 }
            guard lineCount <= 100_000 else { throw Failure.complexity }
        }
        try PreviewConversion.check()
        let fragment = try convert(text, format, url)
        try PreviewConversion.check()
        guard fragment.body.utf8.count <= DocumentSizeLimits.htmlBytes else { throw Failure.complexity }
        var images = PreviewImages(directory: directory(of: url))
        var safe = fragment
        safe.body = try PreviewMarkup.clean(fragment.body) { allowsImages ? images.source($0) : nil }
        guard let theme else { throw CocoaError(.fileReadUnknown) }
        try PreviewConversion.check()
        let fonts = MathRenderer.fontFaces(for: safe.body)
        try PreviewConversion.check()
        let html = try HTMLDocumentBuilder.build(
            fragment: safe, format: format, theme: theme, language: Locale.preferredLanguages.first ?? "en",
            finish: screenCSS + "\n" + fonts, previewPolicy: policy,
            checkSourceBytes: { bytes in
                try PreviewConversion.check()
                guard bytes <= maximumHTMLBytes else { throw Failure.oversizedReply }
            })
        try PreviewConversion.check()
        return Self(html: html, attachments: images.attachments)
    }

    private static func directory(of url: URL) -> URL? {
        (try? ConfinedFile.canonicalPath(url.deletingLastPathComponent())).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func nativeFragment(_ text: String, format: DocumentFormat, url: URL) throws -> HTMLFragment {
        let directory = directory(of: url)
        let imageExists: @Sendable (URL) -> Bool = { candidate in
            guard let directory, PreviewImages.extensions[candidate.pathExtension.lowercased()] != nil,
                let path = try? ConfinedFile.canonicalPath(candidate)
            else { return false }
            return path.hasPrefix(directory.path == "/" ? "/" : directory.path + "/")
        }
        return switch format {
        case .markdown: MarkdownConverter.convert(text)
        case .org: OrgConverter.convert(text, fileName: url.lastPathComponent)
        case .mediawiki:
            // The image predicate excludes the directory itself, disabling the reader's directory listing fallback.
            MediaWikiConverter.convert(text, directory: directory, imageExists: imageExists)
        case .rst:
            RSTConverter.convert(text, directory: directory, readsIncludes: false, permitsFile: imageExists)
        case .latex:
            LaTeXConverter.convert(
                text, directory: directory, imageExists: imageExists, canProbePictureFallback: { _ in false })
        case .quarto, .rMarkdown: ComputationalMarkdown.convert(text, format: format)
        case .notebook: try NotebookConverter.convert(text)
        default: throw Failure.unsupported
        }
    }
}
