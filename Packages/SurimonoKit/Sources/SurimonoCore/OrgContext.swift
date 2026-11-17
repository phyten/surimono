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
    var numbers: [String: Int] = [:]
    var noteDepths: [String: Int] = [:]
    var references: [String: Int] = [:]
    /// Definitions from `#+LATEX_HEADER:` lines, given to every formula.
    var mathDefinitions = ""
    var equationCount = 0

    /// A formula as HTML, or its source marked as unreadable. The discovery pass draws nothing.
    func formula(_ latex: String, display: Bool, source: String) -> String {
        guard !discovering else { return "" }
        return MathRenderer.html(latex, display: display, macros: mathDefinitions)
            ?? MathRenderer.fallback(source, display: display)
    }

    func directive(_ key: String, value: String) {
        if ["TITLE", "SUBTITLE", "AUTHOR", "DATE", "LANGUAGE"].contains(key) { metadata[key] = value }
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
        if numbers[label] == nil {
            order.append(label)
            numbers[label] = order.count
            noteDepths[label] = depth
        }
        let number = numbers[label] ?? 1
        references[label, default: 0] += 1
        let count = references[label] ?? 1
        let anchor = count == 1 ? "fnref-\(number)" : "fnref-\(number)-\(count)"
        return "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"\(anchor)\">\(number)</a></sup>"
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
