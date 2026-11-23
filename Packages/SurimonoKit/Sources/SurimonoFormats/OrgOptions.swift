import Foundation

/// How an Org document is read where its own `#+OPTIONS:` lines say nothing. The document's options always win.
///
/// Three keys are covered: `num`, `toc` and `^`. Everything else is read as before, whatever Emacs would do.
public struct OrgReadingDefaults: Equatable, Sendable {
    /// How far down the outline something reaches.
    public enum Depth: Equatable, Sendable {
        case off
        case all
        case levels(Int)

        var limit: Int {
            switch self {
            case .off: 0
            case .all: Int.max
            case .levels(let count): max(0, count)
            }
        }
    }

    /// Which `a_b` and `a^b` become subscripts and superscripts.
    public enum Scripts: Equatable, Sendable {
        case off
        /// Only `a_{b}` and `a^{b}`: file and variable names keep their underscores.
        case braces
        case all
    }

    /// `num`
    public var sectionNumbers: Depth
    /// `toc`
    public var tableOfContents: Depth
    /// `^`
    public var scripts: Scripts
    /// `H`, which only the document can set. Here it limits the table of contents and nothing else: deeper
    /// headlines still print as headings, where Emacs turns them into list items.
    var headlineLevels = 3

    public init(sectionNumbers: Depth, tableOfContents: Depth, scripts: Scripts) {
        self.sectionNumbers = sectionNumbers
        self.tableOfContents = tableOfContents
        self.scripts = scripts
    }

    /// Surimono's own: notes stay as written, without numbers or a table of contents nobody asked for.
    public static let surimono = OrgReadingDefaults(sectionNumbers: .off, tableOfContents: .off, scripts: .braces)
}

/// What the document's `#+OPTIONS:` lines set. A key they leave out stays `nil`, apart from an explicit `nil`
/// value, so a reading setting can fill in only what the document did not decide.
struct OrgExportOptions: Equatable {
    var sectionNumbers: OrgReadingDefaults.Depth?
    var tableOfContents: OrgReadingDefaults.Depth?
    var scripts: OrgReadingDefaults.Scripts?
    var headlineLevels: Int?

    /// Reads the value of one `#+OPTIONS:` line. A later line overrides the keys it repeats.
    ///
    /// Items are cut as Emacs cuts them: a key up to the first colon, then a value that is either one
    /// parenthesized group or a run without white space. So a `num:t` inside another key's parentheses is not an
    /// item, and a key without a value sets nothing. Keys are matched without regard to case.
    mutating func read(_ line: String) {
        guard let items = orgExpression(#"(.+?):(\(.*?\)|\S+)?[ \t]*"#) else { return }
        let text = line as NSString
        for item in items.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            guard item.range(at: 2).location != NSNotFound else { continue }
            let value = text.substring(with: item.range(at: 2))
            switch text.substring(with: item.range(at: 1)).lowercased() {
            case "num": sectionNumbers = Self.depth(value)
            case "toc": tableOfContents = Self.depth(value)
            case "h": if let levels = Self.integer(value), levels >= 0 { headlineLevels = levels }
            case "^":
                scripts =
                    switch value {
                    case "nil", "()": OrgReadingDefaults.Scripts.off
                    case "{}": .braces
                    default: .all
                    }
            default: break
            }
        }
    }

    /// The value as Emacs's reader takes it: `nil` is off and a whole number is a depth. Anything else is true,
    /// and so is a negative number, which Emacs does not take for a depth.
    private static func depth(_ value: String) -> OrgReadingDefaults.Depth {
        if value == "nil" || value == "()" { return .off }
        guard let levels = integer(value), levels >= 0 else { return .all }
        return levels == 0 ? .off : .levels(levels)
    }

    /// An integer in Lisp's spelling: a sign, digits and an optional final dot. One too large to hold counts as
    /// the largest.
    private static func integer(_ value: String) -> Int? {
        var digits = Substring(value)
        if digits.hasSuffix(".") { digits.removeLast() }
        let negative = digits.hasPrefix("-")
        if negative || digits.hasPrefix("+") { digits.removeFirst() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let magnitude = Int(digits) ?? Int.max
        return negative ? -magnitude : magnitude
    }

    func resolved(over defaults: OrgReadingDefaults) -> OrgReadingDefaults {
        var reading = defaults
        reading.sectionNumbers = sectionNumbers ?? defaults.sectionNumbers
        reading.tableOfContents = tableOfContents ?? defaults.tableOfContents
        reading.scripts = scripts ?? defaults.scripts
        reading.headlineLevels = headlineLevels ?? defaults.headlineLevels
        return reading
    }
}

/// The outline of one conversion: numbers, anchors and the entries of the tables of contents.
struct OrgOutline {
    struct Entry {
        /// 1 for the document's shallowest headline.
        let level: Int
        let id: String
        /// The heading's inline HTML, with its number, without links and footnote marks.
        let html: String
        let listed: Bool
    }

    /// One table of contents. Equal requests give the same table.
    struct Request: Hashable {
        /// The levels below the starting point, or all the headline levels.
        var depth: Int?
        /// For `local`: the number of entries before the keyword and the level of the heading it stands under.
        var after: Int?
        var level: Int?
    }

    /// What follows `#+TOC:` when it asks for the headlines: `headlines`, `headlines 2`, `headlines 2 local`.
    /// The discovery pass and the rendering pass both ask here, so they agree on which lines count.
    static func keyword(_ value: String) -> (depth: Int?, local: Bool)? {
        let words = value.lowercased().split(whereSeparator: \.isWhitespace)
        guard words.first == "headlines" else { return nil }
        return (words.dropFirst().compactMap { Int($0) }.first, words.contains("local"))
    }

    /// As many entries as all the tables of one document may list together; tables beyond that stay empty.
    /// A keyword costs one line and can ask for every heading again.
    static let entryBudget = 50_000

    /// The number of stars of the shallowest headline, known after the discovery pass.
    var shallowest: Int?
    var entries: [Entry] = []
    var requests: [Request] = []
    private var counters: [Int] = []
    private var usedIDs: Set<String> = []
    private var nextSuffix: [String: Int] = [:]
    /// `:UNNUMBERED:` values, each for the subtree of the headline at `level`.
    private var unnumbered: [(level: Int, value: String)] = []

    /// The nearest `:UNNUMBERED:` value that applies to a headline at `level` with these properties.
    mutating func unnumberedValue(level: Int, properties: [String: String]) -> String? {
        unnumbered.removeAll { $0.level >= level }
        if let value = properties["UNNUMBERED"] { unnumbered.append((level, value)) }
        guard let value = unnumbered.last?.value, value != "nil" else { return nil }
        return value
    }

    /// The next number at `level`, such as `1.2.`. A skipped level counts as 0, as in Emacs.
    mutating func nextNumber(level: Int) -> String {
        while counters.count < level { counters.append(0) }
        counters.removeLast(counters.count - level)
        counters[level - 1] += 1
        return counters.map(String.init).joined(separator: ".") + "."
    }

    /// Keeps an id the document wrote itself away from the ids made here.
    mutating func reserve(_ id: String) {
        usedIDs.insert(id)
    }

    /// An id no other heading has, from the heading's text: a repeated one gets `-1`, `-2`… A heading whose text
    /// reads like a footnote's id (`fn-1`, `fnref-1-2`) gets another stem, so no suffix can land on one either.
    mutating func id(for text: String) -> String {
        let slug = MarkdownExtensions.slug(text.trimmingCharacters(in: .whitespaces))
        let base = slug.isEmpty ? "section" : (Self.isNoteID(slug) ? "section-" + slug : slug)
        var candidate = base
        // The suffix only grows, and it starts after the last one given out for this stem, so many headings
        // with one title do not try the same ids again. The used ids are finite, so the search ends.
        var suffix = nextSuffix[base] ?? 0
        while usedIDs.contains(candidate) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        nextSuffix[base] = suffix
        usedIDs.insert(candidate)
        return candidate
    }

    /// `fn-` or `fnref-` and then only digits and hyphens: every id the footnotes use, and every suffix of one.
    private static func isNoteID(_ id: String) -> Bool {
        guard let prefix = ["fnref-", "fn-"].first(where: id.hasPrefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// A table of contents as nested lists and the number of its entries, or nothing when no heading belongs in
    /// it.
    func contents(_ request: Request, headlineLevels: Int, title: String) -> (html: String, count: Int) {
        var candidates = entries[...]
        var base = 0
        if let after = request.after, let level = request.level {
            candidates = entries[min(after, entries.count)...].prefix { $0.level > level }
            base = level
        }
        // The room left under the starting point bounds the depth before anything is added to it.
        let room = headlineLevels - base
        guard room > 0 else { return ("", 0) }
        let limit = base + min(max(0, request.depth ?? room), room)
        let listed = candidates.filter { $0.listed && $0.level <= limit }
        guard let top = listed.map(\.level).min() else { return ("", 0) }
        var html = "<nav class=\"toc\" role=\"doc-toc\">"
        if request.after == nil { html += "<p class=\"toc-title\">\(HTML.escape(title))</p>" }
        // For each open list, whether an item is open in it. A list opens only inside an item, so an entry that
        // skips a level stands in an item without a link, as in Emacs.
        var open: [Bool] = []
        for entry in listed {
            let level = entry.level - top + 1
            while open.count > level {
                if open.removeLast() { html += "</li>" }
                html += "</ul>"
            }
            if open.count == level, open[level - 1] { html += "</li>" }
            while open.count < level {
                if let last = open.indices.last, !open[last] {
                    html += "<li>"
                    open[last] = true
                }
                html += "<ul>"
                open.append(false)
            }
            html += "<li><a href=\"#\(HTML.escape(entry.id))\">\(entry.html)</a>"
            open[level - 1] = true
        }
        while !open.isEmpty {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
        }
        return (html + "</nav>\n", listed.count)
    }
}
