import Foundation
import SurimonoFormats

/// The readers of SurimonoFormats, called as `DocumentRenderer.themedFragment` calls them, for tests that must not
/// depend on Rendering. Decoding is lenient here (the app refuses text that does not decode cleanly), so more
/// unusual text reaches the readers.
package enum FormatsReader {
    /// The formats whose reader lives in SurimonoFormats.
    package static let formats: [DocumentFormat] = DocumentFormat.allCases.filter {
        $0 != .pdf && $0 != .image && $0 != .zipArchive
    }

    /// Converts the document at `url` (its bytes are `data`). Companion files resolve against the same folder, so an
    /// include of `self` reads the document again.
    package static func read(_ format: DocumentFormat, data: Data, url: URL) throws -> HTMLFragment? {
        let directory = url.deletingLastPathComponent()
        let readFile: @Sendable (URL) -> Data? = { file in
            guard file.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else { return nil }
            return try? Data(contentsOf: file)
        }
        if format == .docx { return try DocxConverter.convert(data) }
        let text = TextDecoding.decode(data).text
        return switch format {
        case .markdown: MarkdownConverter.convert(text, directory: directory, readFile: readFile)
        case .graphviz, .plantuml: DiagramConverter.convert(text, format: format)
        case .quarto, .rMarkdown: ComputationalMarkdown.convert(text)
        case .djot: try DjotConverter.convert(text)
        case .rst: RSTConverter.convert(text, directory: directory)
        case .mediawiki: MediaWikiConverter.convert(text, directory: directory, imageExists: { _ in false })
        case .textile: try TextileConverter.convert(text)
        case .asciidoc: try AsciiDocConverter.convert(text)
        case .notebook: try NotebookConverter.convert(text)
        case .latex:
            LaTeXConverter.convert(
                text, fontIndex: InstalledFontIndex(faces: [:]), documentURL: url, readFile: readFile)
        case .org: OrgConverter.convert(text)
        case .plainText: PlainTextConverter.convert(text, fileExtension: url.pathExtension)
        case .csv: CSVConverter.convert(text, delimiter: CSVConverter.guessedDelimiter(of: text))
        case .html:
            HTMLFragment(
                body: (DocumentOutline.title(ofHTML: text) ?? "") + "\(DocumentOutline.headings(inHTML: text).count)")
        default: nil
        }
    }
}
