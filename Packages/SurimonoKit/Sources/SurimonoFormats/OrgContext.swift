import Foundation

struct OrgTaskKeywords: Equatable {
    static let directives: Set<String> = ["TODO", "SEQ_TODO", "TYP_TODO"]
    private(set) var active: Set<String> = ["TODO"]
    private(set) var done: Set<String> = ["DONE"]
    private(set) var declared = false

    mutating func declare(_ value: String) {
        if !declared {
            active = []
            done = []
            declared = true
        }
        let words = value.split(whereSeparator: \.isWhitespace).map { String($0.prefix(while: { $0 != "(" })) }
        let divider = words.firstIndex(of: "|") ?? max(0, words.count - 1)
        active.formUnion(words.prefix(divider).filter { !$0.isEmpty })
        done.formUnion(words.dropFirst(divider).filter { !$0.isEmpty && $0 != "|" })
    }

    func contains(_ word: String) -> Bool { active.contains(word) || done.contains(word) }
}

// A conversion owns this state; nested parsers share numbering without sharing it across documents.
final class OrgContext {
    var metadata: [String: String] = [:]
    var taskKeywords = OrgTaskKeywords()
    // Additional familiar states are styled in files without a workflow declaration.
    static let styledActive: Set<String> = ["TODO", "NEXT", "WAITING", "WAIT", "HOLD"]
    static let styledDone: Set<String> = ["DONE", "CANCELLED", "CANCELED"]
    var active: Set<String> { taskKeywords.declared ? taskKeywords.active : Self.styledActive }
    var done: Set<String> { taskKeywords.declared ? taskKeywords.done : Self.styledDone }
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
    private var mathDefinitions = MathDefinitions()
    var equationCount = 0
    /// What the document's `#+OPTIONS:` lines set, gathered by the discovery pass.
    var options = OrgExportOptions()
    /// The options over the defaults; the discovery pass reads with the defaults alone.
    var reading: OrgReadingDefaults
    lazy var drawerNames = OrgNameFilter(reading.drawers)
    lazy var propertyNames = OrgNameFilter(reading.properties)
    var outline = OrgOutline()
    var subtrees = OrgSubtrees()
    var commentEnds: [Int: Int] = [:]
    var omissions: [Int: Int] = [:]
    var repeatingDiscovery = false
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
        guard let macros = mathDefinitions.preamble(for: latex) else {
            return MathRenderer.fallback(source, display: display)
        }
        return MathRenderer.html(
            latex, display: display, macros: macros, rowNumberHTML: [], reportTruncation: false,
            originalSource: MathRenderer.withoutDelimiters(source))
            ?? MathRenderer.fallback(source, display: display)
    }

    func directive(_ key: String, value: String, lineNumber: Int, line: String, lines: [String]) {
        if key == "TOC", OrgOutline.keyword(value) != nil {
            hasContentsKeyword = true
            options.file.note(.bodyContents, source: .init(fileName: fileName, lineNumber: lineNumber, rawText: line))
        }
        guard !repeatingDiscovery else { return }
        if key == "FILETAGS" {
            subtrees.fileTags.formUnion(value.split { $0 == ":" || $0.isWhitespace }.map(String.init))
        }
        if key == "SELECT_TAGS" {
            if subtrees.select == nil { subtrees.select = [] }
            subtrees.select?.formUnion(value.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        if key == "EXCLUDE_TAGS" {
            if subtrees.exclude == nil { subtrees.exclude = [] }
            subtrees.exclude?.formUnion(value.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        if ["TITLE", "SUBTITLE", "AUTHOR", "DATE", "LANGUAGE"].contains(key) { metadata[key] = value }
        if key == "OPTIONS" { options.read(value, fileName: fileName, lineNumber: lineNumber, lines: lines) }
        if key == "LATEX_HEADER" || key == "LATEX_HEADER_EXTRA",
            !value.isEmpty
        {
            if mathDefinitions.preview != nil {
                if discovering { mathDefinitions.preview?.appendHeader(value) }
            } else if let definition = OrgMath.definition(value),
                MathRenderer.html("x", display: false, macros: mathDefinitions.source + definition) != nil
            {
                mathDefinitions.source += definition
            }
        }
        if OrgTaskKeywords.directives.contains(key) { taskKeywords.declare(value) }
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
