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
    /// first markup appears; Markdown shows plain text and HTML fragments as they are anyway. A feed that knows its
    /// format says so in Marked's way, with a comment at the top (`<!--format: org-->`), which is taken off.
    public static func streaming(text: String?) -> ClipboardContent {
        guard let text else { return .empty }
        let (hint, body) = streamingHeader(of: text)
        guard body.contains(where: { !$0.isWhitespace }) else { return .empty }
        let format = hint ?? (isHTMLDocument(String(body)) ? .html : .markdown)
        return .document(data: Data(body.utf8), format: format)
    }

    /// Marked's header: one comment at the very top whose lines are all `source:` or `format:` (any case, the space
    /// after the colon optional). Any other comment is the document's own and stays.
    private static func streamingHeader(of text: String) -> (format: DocumentFormat?, body: Substring) {
        let start = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        guard start.hasPrefix("<!--"), let end = start.range(of: "-->") else { return (nil, text[...]) }
        let lines = start[start.index(start.startIndex, offsetBy: 4)..<end.lowerBound]
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var format: DocumentFormat?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return (nil, text[...]) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "source" || key == "format" else { return (nil, text[...]) }
            if key == "format" {
                format = streamingFormat(named: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        guard !lines.isEmpty else { return (nil, text[...]) }
        return (format, start[end.upperBound...].drop(while: \.isWhitespace))
    }

    /// Formats that are text a feed can type. A name this app does not read (Marked's `fountain`) gives none, and the
    /// text is then read as usual.
    private static func streamingFormat(named name: String) -> DocumentFormat? {
        let name = name.lowercased()
        let aliases: [String: DocumentFormat] = [
            "multimarkdown": .markdown, "gfm": .markdown, "commonmark": .markdown, "org-mode": .org, "orgmode": .org,
            "plain": .plainText, "plaintext": .plainText, "quarto": .quarto, "r markdown": .rMarkdown,
            "graphviz": .graphviz,
        ]
        guard let format = aliases[name] ?? DocumentFormat(fileExtension: name), format.isWebRendered,
            format != .docx
        else { return nil }
        return format
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
        case .mediawiki: "mediawiki"
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
