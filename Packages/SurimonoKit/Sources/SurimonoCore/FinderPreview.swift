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

    private enum Failure: Error {
        case encoding
        case unsupported
    }

    public static func make(for url: URL, bundle: Bundle = .main) -> Self {
        var sourceBytes = 0
        do {
            let format =
                DocumentFormat(fileExtension: url.pathExtension)
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType).flatMap(
                    DocumentFormat.init(contentType:))
            guard let format else { throw Failure.unsupported }
            let limitedReaders: Set<DocumentFormat> = [.asciidoc, .textile, .djot, .mediawiki]
            let limit =
                limitedReaders.contains(format) ? DocumentSizeLimits.markupReaderBytes : DocumentSizeLimits.textBytes
            let descriptor = try ConfinedFile.open(url)
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            sourceBytes = Int(info.st_size)
            guard sourceBytes <= limit else { throw CocoaError(.fileReadTooLarge) }
            let data: Data
            do {
                data = try ConfinedFile.readBytes(descriptor, size: sourceBytes, maximumSize: limit)
            } catch CocoaError.fileReadTooLarge {
                sourceBytes = limit + 1
                throw CocoaError(.fileReadTooLarge)
            }
            sourceBytes = data.count
            return try build(data, format: format, url: url)
        } catch {
            func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
            let message: String
            switch error {
            case Failure.encoding: message = localized("The text encoding could not be read without data loss.")
            case Failure.unsupported: message = localized("This document format is not supported.")
            case CocoaError.fileReadTooLarge:
                message = String.localizedStringWithFormat(
                    localized("This file is too large to lay out as pages (%lld MB)."),
                    Int64(ceil(Double(sourceBytes) / 1_000_000)))
            default: message = localized("The document could not be loaded.")
            }
            return errorPage(message)
        }
    }

    static func errorPage(_ message: String) -> Self {
        Self(
            html:
                "<!doctype html><html><head><meta charset=\"utf-8\">\(policy)</head><body><p>\(HTML.escape(message))</p></body></html>",
            attachments: [:])
    }

    private static func build(_ data: Data, format: DocumentFormat, url: URL) throws -> Self {
        guard let text = TextDecoding.losslessText(data) else { throw Failure.encoding }
        var lineCount = 1
        for byte in text.utf8 where byte == 10 {
            lineCount += 1
            guard lineCount <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
        }
        let directory = (try? ConfinedFile.canonicalPath(url.deletingLastPathComponent())).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let imageExists: @Sendable (URL) -> Bool = { candidate in
            guard let directory, PreviewImages.imageExtensions.contains(candidate.pathExtension.lowercased()),
                let path = try? ConfinedFile.canonicalPath(candidate)
            else { return false }
            return path.hasPrefix(directory.path == "/" ? "/" : directory.path + "/")
        }
        let fragment: HTMLFragment
        switch format {
        case .markdown: fragment = MarkdownConverter.convert(text)
        case .org: fragment = OrgConverter.convert(text, fileName: url.lastPathComponent)
        case .asciidoc: fragment = try AsciiDocConverter.convert(text, fallsBackToSource: false)
        case .djot: fragment = try DjotConverter.convert(text, fallsBackToSource: false)
        case .textile: fragment = try TextileConverter.convert(text, fallsBackToSource: false)
        case .rst:
            fragment = RSTConverter.convert(text, directory: directory, readsIncludes: false, permitsFile: imageExists)
        case .latex:
            fragment = LaTeXConverter.convert(
                text, directory: directory, imageExists: imageExists, canProbePictureFallback: { _ in false })
        case .mediawiki:
            guard text.utf8.count <= DocumentSizeLimits.markupReaderBytes else { throw CocoaError(.fileReadTooLarge) }
            fragment = MediaWikiConverter.convert(text, directory: directory, imageExists: imageExists)
        case .quarto, .rMarkdown: fragment = ComputationalMarkdown.convert(text)
        case .notebook: fragment = try NotebookConverter.convert(text)
        default: throw Failure.unsupported
        }
        func check(_ count: Int) throws {
            guard count <= DocumentSizeLimits.htmlBytes else { throw CocoaError(.fileReadTooLarge) }
        }
        try check(fragment.body.utf8.count)
        var images = PreviewImages(directory: directory)
        var safe = fragment
        safe.body = try PreviewMarkup.clean(fragment.body) { images.source($0) }
        guard let theme else { throw CocoaError(.fileReadUnknown) }
        let fonts = MathRenderer.fontFaces(for: safe.body)
        let html = try HTMLDocumentBuilder.build(
            fragment: safe, format: format, theme: theme, language: Locale.preferredLanguages.first ?? "en",
            finish: screenCSS + "\n" + fonts, previewPolicy: policy, checkSourceBytes: check)
        try check(html.utf8.count)
        return Self(html: html, attachments: images.attachments)
    }
}
