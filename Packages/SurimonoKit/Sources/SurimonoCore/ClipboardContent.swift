import Foundation

public enum ClipboardContent: Equatable, Sendable {
    case files([URL])
    /// Text whose format is decided later by `ClipboardFormatDetector`, with what the pasteboard said about it.
    case text(String, hints: ClipboardFormatHints)
    case document(data: Data, format: DocumentFormat)
    case empty

    public init(
        fileURLs: [URL] = [], text: String? = nil, hints: ClipboardFormatHints = .init(), png: Data? = nil,
        tiff: Data? = nil
    ) {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty {
            self = .files(files)
        } else if let text {
            guard text.contains(where: { !$0.isWhitespace }) else {
                self = .empty
                return
            }
            self = .text(text, hints: hints)
        } else if let image = [png, tiff].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            self = .document(data: image, format: .image)
        } else {
            self = .empty
        }
    }

    /// Text fed to a live preview. Editors stream whatever is being typed, so a guess at its format would flip as the
    /// first markup appears; Markdown shows plain text and HTML fragments as they are anyway.
    public static func streaming(text: String?) -> ClipboardContent {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return .empty }
        let format: DocumentFormat = isHTMLDocument(text) ? .html : .markdown
        return .document(data: Data(text.utf8), format: format)
    }

    /// The extension of a file that keeps what opened from memory as it is.
    public static func fileExtension(of data: Data, format: DocumentFormat) -> String {
        switch format {
        case .markdown: "md"
        case .html: "html"
        case .org: "org"
        case .latex: "tex"
        case .quarto: "qmd"
        case .rMarkdown: "Rmd"
        case .djot: "dj"
        case .docx: "docx"
        case .textile: "textile"
        case .asciidoc: "adoc"
        case .notebook: "ipynb"
        case .graphviz: "dot"
        case .plantuml: "puml"
        case .csv: CSVConverter.guessedDelimiter(of: TextDecoding.decode(data).text) == "\t" ? "tsv" : "csv"
        case .image: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "tiff"
        default: "txt"
        }
    }

    private static func isHTMLDocument(_ text: String) -> Bool {
        var htmlStart = text[...]
        while true {
            htmlStart = htmlStart.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            guard htmlStart.hasPrefix("<!--"), let end = htmlStart.range(of: "-->") else { break }
            htmlStart = htmlStart[end.upperBound...]
        }
        return htmlStart.range(
            of: #"\A(?:<!doctype\s+html\b|<html\b)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
