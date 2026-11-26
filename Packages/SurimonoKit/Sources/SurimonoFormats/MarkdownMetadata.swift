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
    var contentsInstructions = ReadingFileInstructions()
    var numberInstructions = ReadingFileInstructions()
    var contentsTitle: String?
    public var hasCSL = false

    public init() {}

    package init(lines: ArraySlice<String>, plainMarkdown: Bool = true) {
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
            let scalar = Self.withoutComment(raw)
            let items = Self.items(scalar, children: lines[start..<index])
            func instruction<Value>(_ value: Value) -> ReadingInstruction<Value> {
                .init(value, source: ReadingInstructionSource(lines: lines, index: start - 1))
            }
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
                if !plainMarkdown {
                    tableOfContents = items.first?.lowercased() == "true"
                    continue
                }
                contentsInstructions.present = Self.contentsPresence(scalar, items: items).map(instruction)
                tableOfContents = contentsInstructions.present?.value == true
            case "number-sections" where plainMarkdown:
                numberInstructions.present = Bool(scalar.lowercased()).map(instruction)
            case "toc-depth" where plainMarkdown:
                if let count = Int(scalar), count >= 0 {
                    contentsInstructions.depth = instruction(.levels(count))
                }
            case "toc-title" where plainMarkdown:
                if ["|", "|-", "|+", ">", ">-", ">+"].contains(scalar) {
                    let children = lines[start..<index].prefix { $0.isEmpty || $0.first?.isWhitespace == true }
                    contentsTitle = ComputationalMetadata.blockScalar(children, folded: scalar.first == ">")
                } else if !scalar.isEmpty, !scalar.hasPrefix("["), !scalar.hasPrefix("{") {
                    contentsTitle = ComputationalMetadata.scalar(scalar)
                }
            case "csl": hasCSL = true
            default: break
            }
        }
    }

    static func items(_ scalar: String, children: ArraySlice<String>) -> [String] {
        let values: [String]
        if scalar.isEmpty {
            values = children.compactMap { line in
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
        return values.filter { !$0.isEmpty }
    }

    // Earlier readers enabled contents when the first decoded item was true, including quoted values.
    static func contentsPresence(_ scalar: String, items: [String]) -> Bool? {
        items.first?.lowercased() == "true" ? true : Bool(ComputationalMetadata.scalar(scalar).lowercased())
    }

    static func withoutComment(_ value: String) -> String {
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
