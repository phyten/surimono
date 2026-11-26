import Foundation

/// The top-level Pandoc fields that affect the printed document. The nested surimono mapping
/// is read separately since it affects window and print settings rather than document content.
public struct MarkdownMetadata: Equatable, Sendable {
    public var title: String?
    public var authors: [String] = []
    public var date: String?
    public var language: String?
    public var bibliography: [String] = []
    public var referenceSectionTitle: String?
    public var nocite: [String] = []
    public var linkCitations = true
    public var tableOfContents = false
    var tocInstruction: ReadingInstruction<Bool>?
    public var hasCSL = false

    public init() {}

    package init(lines: ArraySlice<String>) {
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1
            guard line.first?.isWhitespace == false, !line.hasPrefix("#"), !line.hasPrefix("- "),
                let (key, raw) = ComputationalMetadata.pair(line)
            else { continue }
            let start = index
            while index < lines.endIndex {
                let next = lines[index]
                if !next.isEmpty, next.first?.isWhitespace != true, !next.hasPrefix("- "), !next.hasPrefix("#") {
                    break
                }
                index += 1
            }
            let values: [String]
            let scalar = Self.withoutComment(raw)
            if scalar.isEmpty {
                values = lines[start..<index].compactMap { line in
                    let item = line.trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("- ") else { return nil }
                    return ComputationalMetadata.scalar(Self.withoutComment(String(item.dropFirst(2))))
                }
            } else if scalar.hasPrefix("["), scalar.hasSuffix("]") {
                values = ComputationalMetadata.items(String(scalar.dropFirst().dropLast())).map(
                    ComputationalMetadata.scalar)
            } else {
                values = [ComputationalMetadata.scalar(scalar)]
            }
            let items = values.filter { !$0.isEmpty }
            switch ComputationalMetadata.scalar(key) {
            case "title": title = items.first
            case "author": authors = items
            case "date": date = items.first
            case "lang", "language": language = items.first
            case "bibliography": bibliography = items
            case "reference-section-title": referenceSectionTitle = items.first
            case "nocite": nocite = items
            case "link-citations": linkCitations = items.first?.lowercased() != "false"
            case "toc":
                tableOfContents = items.first?.lowercased() == "true"
                tocInstruction = .init(tableOfContents, source: .init(fileName: nil, lineNumber: start, rawText: line))
            case "csl": hasCSL = true
            default: break
            }
        }
    }

    private static func withoutComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        var previousWasSpace = true
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if quote == "\"", character == "\\" {
                escaped = true
            } else if character == quote {
                quote = nil
            } else if quote == nil, character == "\"" || character == "'" {
                quote = character
            } else if quote == nil, character == "#", previousWasSpace {
                return value[..<index].trimmingCharacters(in: .whitespaces)
            }
            previousWasSpace = character.isWhitespace
        }
        return value
    }

    func titleBlock() -> String {
        guard let title else { return "" }
        var html = "<header class=\"latex-title-block\">\n<h1 class=\"latex-title\">\(HTML.escape(title))</h1>\n"
        if !authors.isEmpty {
            let names = authors.map { "<span class=\"latex-author-name\">\(HTML.escape($0))</span>" }
            html += "<p class=\"latex-author\">\(names.joined(separator: " "))</p>\n"
        }
        if let date { html += "<p class=\"latex-date\">\(HTML.escape(date))</p>\n" }
        return html + "</header>\n"
    }
}
