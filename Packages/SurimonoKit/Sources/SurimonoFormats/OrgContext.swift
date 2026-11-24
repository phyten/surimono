import Foundation

// A conversion owns this state; nested parsers share numbering without sharing it across documents.
final class OrgContext {
    var metadata: [String: String] = [:]
    var active: Set<String> = ["TODO", "NEXT", "WAITING", "WAIT", "HOLD"]
    var done: Set<String> = ["DONE", "CANCELLED", "CANCELED"]
    var customKeywords = false
    var discovering = false
    var definitions: [String: String] = [:]
    var anonymous = 0
    var order: [String] = []
    struct Note {
        let number: Int
        let id: String
        let depth: Int
        var references = 0
    }
    var notes: [String: Note] = [:]
    var propertiesByHeading: [Int: [String: String]] = [:]
    /// Definitions from `#+LATEX_HEADER:` lines, given to every formula.
    var mathDefinitions = ""
    var equationCount = 0
    /// What the document's `#+OPTIONS:` lines set, gathered by the discovery pass.
    var options = OrgExportOptions()
    /// The options over the defaults; the discovery pass reads with the defaults alone.
    var reading: OrgReadingDefaults
    var outline = OrgOutline()
    /// Whether a `#+TOC: headlines` line asks for a table of contents somewhere in the text.
    var hasContentsKeyword = false
    /// Marks where a table of contents goes until every heading is known. Random, so no document can write it.
    let contentsToken = UUID().uuidString

    let fileName: String?

    init(defaults: OrgReadingDefaults = .surimono, fileName: String? = nil) {
        self.fileName = fileName
        reading = defaults
    }

    /// Headings need anchors only when a table of contents links to them.
    var anchorsHeadings: Bool { reading.tableOfContents.limit > 0 || hasContentsKeyword }

    /// A formula as HTML, or its source marked as unreadable. The discovery pass draws nothing.
    func formula(_ latex: String, display: Bool, source: String) -> String {
        guard !discovering else { return "" }
        return MathRenderer.html(
            latex, display: display, macros: mathDefinitions, rowNumberHTML: [], reportTruncation: false,
            originalSource: MathRenderer.withoutDelimiters(source))
            ?? MathRenderer.fallback(source, display: display)
    }

    func directive(_ key: String, value: String, lineNumber: Int, line: String) {
        if ["TITLE", "SUBTITLE", "AUTHOR", "DATE", "LANGUAGE"].contains(key) { metadata[key] = value }
        if key == "OPTIONS" { options.read(value, fileName: fileName, lineNumber: lineNumber) }
        if key == "TOC", OrgOutline.keyword(value) != nil {
            hasContentsKeyword = true
            options.file.note(.init(fileName: fileName, lineNumber: lineNumber, rawText: line), for: .tableOfContents)
        }
        if key == "LATEX_HEADER" || key == "LATEX_HEADER_EXTRA",
            let definition = OrgMath.definition(value, after: mathDefinitions)
        {
            mathDefinitions += definition
        }
        guard ["TODO", "SEQ_TODO", "TYP_TODO"].contains(key) else { return }
        if !customKeywords {
            active = []
            done = []
            customKeywords = true
        }
        let words = value.split(whereSeparator: \.isWhitespace).map { String($0.prefix(while: { $0 != "(" })) }
        let divider = words.firstIndex(of: "|") ?? max(0, words.count - 1)
        active.formUnion(words.prefix(divider).filter { !$0.isEmpty })
        done.formUnion(words.dropFirst(divider).filter { !$0.isEmpty && $0 != "|" })
    }

    func reference(_ label: String, depth: Int) -> String? {
        guard !discovering, definitions[label] != nil else { return nil }
        var note: Note
        if let existing = notes[label] {
            note = existing
        } else {
            order.append(label)
            note = Note(number: order.count, id: outline.allocateID("fn-\(order.count)"), depth: depth)
        }
        note.references += 1
        notes[label] = note
        let base = "fnref-\(note.number)"
        let anchor = outline.allocateID(note.references == 1 ? base : "\(base)-\(note.references)")
        return "<sup class=\"footnote-ref\"><a href=\"#\(note.id)\" id=\"\(anchor)\">\(note.number)</a></sup>"
    }
}

// The lock protects all cache access, including compilation. Regex instances are immutable after creation.
private final class OrgExpressions: @unchecked Sendable {
    static let shared = OrgExpressions()
    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]

    func expression(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = expressions[pattern] { return existing }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        expressions[pattern] = regex
        return regex
    }
}

func orgExpression(_ pattern: String) -> NSRegularExpression? {
    OrgExpressions.shared.expression(pattern)
}

func orgCaptures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = orgExpression(pattern),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}
