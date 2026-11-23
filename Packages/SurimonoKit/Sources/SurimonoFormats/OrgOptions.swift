import Foundation

/// How an Org document is read where its own `#+OPTIONS:` lines say nothing. The document's options always win.
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
    /// `H`: the levels that count as headlines. It limits the table of contents; deeper headlines still print as
    /// headings, where Emacs turns them into list items.
    public var headlineLevels: Int

    public init(sectionNumbers: Depth, tableOfContents: Depth, scripts: Scripts, headlineLevels: Int = 3) {
        self.sectionNumbers = sectionNumbers
        self.tableOfContents = tableOfContents
        self.scripts = scripts
        self.headlineLevels = headlineLevels
    }

    /// Surimono's own: notes stay as written, without numbers or a table of contents nobody asked for.
    public static let surimono = OrgReadingDefaults(sectionNumbers: .off, tableOfContents: .off, scripts: .braces)
    /// What Emacs's HTML export does with a file that sets nothing.
    public static let emacs = OrgReadingDefaults(sectionNumbers: .all, tableOfContents: .all, scripts: .all)

    public func with(
        sectionNumbers: Depth? = nil, tableOfContents: Depth? = nil, scripts: Scripts? = nil,
        headlineLevels: Int? = nil
    ) -> OrgReadingDefaults {
        OrgReadingDefaults(
            sectionNumbers: sectionNumbers ?? self.sectionNumbers,
            tableOfContents: tableOfContents ?? self.tableOfContents, scripts: scripts ?? self.scripts,
            headlineLevels: headlineLevels ?? self.headlineLevels)
    }
}

/// What the document's `#+OPTIONS:` lines set. A key they leave out stays `nil`, apart from an explicit `nil`
/// value, so a reading setting can fill in only what the document did not decide.
struct OrgExportOptions: Equatable {
    var sectionNumbers: OrgReadingDefaults.Depth?
    var tableOfContents: OrgReadingDefaults.Depth?
    var scripts: OrgReadingDefaults.Scripts?
    var headlineLevels: Int?

    /// Reads the value of one `#+OPTIONS:` line. A later line overrides the keys it repeats.
    mutating func read(_ line: String) {
        for item in line.split(whereSeparator: \.isWhitespace) {
            // The key is at least one character, so `::nil` has the key `:`.
            guard let colon = item.dropFirst().firstIndex(of: ":") else { continue }
            let value = String(item[item.index(after: colon)...])
            switch String(item[..<colon]) {
            case "num": sectionNumbers = Self.depth(value)
            case "toc": tableOfContents = Self.depth(value)
            case "H": if let levels = Int(value) { headlineLevels = max(0, levels) }
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

    /// Emacs reads the value as Lisp: `nil` is off, a number is a depth, and any other symbol is true.
    private static func depth(_ value: String) -> OrgReadingDefaults.Depth {
        if value == "nil" || value == "()" { return .off }
        if let levels = Int(value) { return levels > 0 ? .levels(levels) : .off }
        return .all
    }

    func resolved(over defaults: OrgReadingDefaults) -> OrgReadingDefaults {
        defaults.with(
            sectionNumbers: sectionNumbers, tableOfContents: tableOfContents, scripts: scripts,
            headlineLevels: headlineLevels)
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

    struct Request {
        /// The levels below the starting point, or all the headline levels.
        let depth: Int?
        /// For `local`: the number of entries before the keyword and the level of the heading it stands under.
        let scope: (after: Int, level: Int)?
    }

    /// The number of stars of the shallowest headline, known after the discovery pass.
    var shallowest: Int?
    var entries: [Entry] = []
    var requests: [Request] = []
    private var counters: [Int] = []
    private var usedIDs: [String: Int] = [:]
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

    mutating func id(custom: String?, text: String) -> String {
        let slug = MarkdownExtensions.slug(text.trimmingCharacters(in: .whitespaces))
        let base = custom ?? (slug.isEmpty ? "section" : slug)
        guard let count = usedIDs[base] else {
            usedIDs[base] = 0
            return base
        }
        usedIDs[base] = count + 1
        return "\(base)-\(count + 1)"
    }

    /// A table of contents as nested lists, or nothing when no heading belongs in it.
    func contents(_ request: Request, headlineLevels: Int, title: String) -> String {
        var candidates = entries[...]
        var base = 0
        if let scope = request.scope {
            candidates = entries[min(scope.after, entries.count)...].prefix { $0.level > scope.level }
            base = scope.level
        }
        let limit = min(headlineLevels, request.depth.map { base + $0 } ?? Int.max)
        let listed = candidates.filter { $0.listed && $0.level <= limit }
        guard let top = listed.map(\.level).min() else { return "" }
        var html = "<nav class=\"toc\" role=\"doc-toc\">"
        if request.scope == nil { html += "<p class=\"toc-title\">\(HTML.escape(title))</p>" }
        var open: [Bool] = []
        for entry in listed {
            let level = entry.level - top + 1
            while open.count < level {
                html += "<ul>"
                open.append(false)
            }
            while open.count > level {
                if open.removeLast() { html += "</li>" }
                html += "</ul>"
            }
            if open.last == true { html += "</li>" }
            html += "<li><a href=\"#\(HTML.escape(entry.id))\">\(entry.html)</a>"
            open[open.count - 1] = true
        }
        while !open.isEmpty {
            if open.removeLast() { html += "</li>" }
            html += "</ul>"
        }
        return html + "</nav>\n"
    }
}
