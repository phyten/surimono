import Foundation

/// How an Org document is read where its own `#+OPTIONS:` lines say nothing. File options win unless the reader
/// explicitly overrides them for that document.
public struct OrgReadingDefaults: Codable, Equatable, Sendable {
    /// How far down the outline something reaches.
    public enum Depth: Codable, Hashable, Sendable {
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
    public enum Scripts: String, Codable, Equatable, Sendable {
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
    public var headlineLevels: Int = 3
    public var tags: Tags = .all
    public var preserveBreaks: Bool = false
    public var emphasis: Bool = true
    public var math: Math = .render
    public var clocks: Bool = true
    public var planning: Bool = false
    public var priority: Bool = false
    public var todo: Bool = true
    public var statistics: Bool = true
    public var tasks: Tasks = .all
    public var title: Bool = true
    public var author: Bool = true
    public var date: Bool = true
    public var drawers: Names = .off
    public var properties: Names = .off
    public var timestamps: Timestamps = .all
    public var footnotes: Bool = true
    public var tables: Bool = true
    public var fixedWidth: Bool = true
    public var archived: Archived = .all

    public static let emacs: Self = {
        var preset = Self(sectionNumbers: .all, tableOfContents: .all, scripts: .all)
        preset.drawers = .excluding(["LOGBOOK"])
        preset.clocks = false
        preset.archived = .headline
        return preset
    }()

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
    var file = OrgFileInstructions()

    /// Reads the value of one `#+OPTIONS:` line. A later line overrides the keys it repeats.
    ///
    /// Consume the value even for unknown keys: spaces and colons inside a Lisp string or list belong to it.
    mutating func read(_ line: String, fileName: String?, lineNumber: Int, lines: [String]) {
        let original = lines[lineNumber - 1]
        let afterColon = original.drop(while: { $0 != ":" }).dropFirst()
        let firstToken = afterColon.drop(while: { $0.isWhitespace }).startIndex
        let prefixLength = original.distance(from: original.startIndex, to: firstToken)
        let chars = Array(line)
        var cursor = 0
        while cursor < chars.count {
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
            let start = cursor
            while cursor < chars.count, chars[cursor] != ":" { cursor += 1 }
            guard cursor < chars.count else { break }
            // The fixed-width option uses a colon as both its key and its separator.
            if cursor == start, cursor + 1 < chars.count, chars[cursor + 1] == ":" { cursor += 1 }
            let key = String(chars[start..<cursor]).lowercased()
            cursor += 1
            guard cursor < chars.count, !chars[cursor].isWhitespace else { continue }
            let valueStart = cursor
            cursor = Self.endOfValue(chars, from: cursor)
            var source = OrgInstructionSource(
                fileName: fileName, lineNumber: lineNumber, rawText: String(chars[start..<cursor]))
            source.excerpt = .init(
                previous: lineNumber > 1 ? lines[lineNumber - 2] : nil, line: original,
                next: lineNumber < lines.count ? lines[lineNumber] : nil, tokenOffset: prefixLength + start)
            apply(key: key, token: chars[valueStart..<cursor], source: source)
        }
    }

    private mutating func apply(key: String, token: ArraySlice<Character>, source: OrgInstructionSource) {
        let emptyList =
            token.first == "(" && token.last == ")" && token.dropFirst().dropLast().allSatisfy(\.isWhitespace)
        let value = emptyList ? "nil" : String(token)
        switch key {
        case "num": file.record(Self.depth(value), for: .sectionNumbers, source: source)
        case "toc": file.record(Self.depth(value), for: .tableOfContents, source: source)
        case "h":
            if let levels = Self.integer(value), levels >= 0 {
                file.record(levels, for: .headlineLevels, source: source)
            }
        case "^":
            let scripts: OrgReadingDefaults.Scripts =
                switch value {
                case "nil", "()": OrgReadingDefaults.Scripts.off
                case "{}": .braces
                default: .all
                }
            file.record(scripts, for: .scripts, source: source)
        case "tags":
            if let selection = OrgReadingDefaults.Tags(rawValue: value) {
                file.record(selection, for: .tags, source: source)
            }
        case "\\n": file.record(value != "nil", for: .preserveBreaks, source: source)
        case "*": file.record(value != "nil", for: .emphasis, source: source)
        case "tex":
            if let selection = OrgReadingDefaults.Math(rawValue: value) {
                file.record(selection, for: .math, source: source)
            }
        case "c": file.record(value != "nil", for: .clocks, source: source)
        case "p": file.record(value != "nil", for: .planning, source: source)
        case "pri": file.record(value != "nil", for: .priority, source: source)
        case "todo": file.record(value != "nil", for: .todo, source: source)
        case "stat": file.record(value != "nil", for: .statistics, source: source)
        case "tasks":
            if let selection = OrgReadingDefaults.Tasks(token: value) {
                file.record(selection, for: .tasks, source: source)
            }
        case "title": file.record(value != "nil", for: .title, source: source)
        case "author": file.record(value != "nil", for: .author, source: source)
        case "date": file.record(value != "nil", for: .date, source: source)
        case "d":
            if let selection = OrgReadingDefaults.Names(token: value, allowsExclusion: true) {
                file.record(selection, for: .drawers, source: source)
            }
        case "prop":
            if let selection = OrgReadingDefaults.Names(token: value, allowsExclusion: false) {
                file.record(selection, for: .properties, source: source)
            }
        case "<":
            if let selection = OrgReadingDefaults.Timestamps(rawValue: value) {
                file.record(selection, for: .timestamps, source: source)
            }
        case "f": file.record(value != "nil", for: .footnotes, source: source)
        case "|": file.record(value != "nil", for: .tables, source: source)
        case ":": file.record(value != "nil", for: .fixedWidth, source: source)
        case "arch":
            if let selection = OrgReadingDefaults.Archived(rawValue: value) {
                file.record(selection, for: .archived, source: source)
            }
        default: break
        }
    }

    private static func endOfValue(_ chars: [Character], from start: Int) -> Int {
        var index = start
        var depth = 0
        var quoted = false
        // Reader prefixes and escaped spaces are part of the same object.
        while index < chars.count {
            if chars[index] == "#", index + 1 < chars.count, chars[index + 1] == "'" {
                index += 2
            } else if "'`".contains(chars[index]) {
                index += 1
            } else {
                break
            }
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }
        // A property-bearing string starts with #( and ends at the matching parenthesis.
        if index + 1 < chars.count, chars[index] == "#", chars[index + 1] == "(" { index += 1 }
        let objectStart = index
        // A symbol ends before the next reader delimiter, even without separating whitespace.
        if index < chars.count, !"([\"".contains(chars[index]) {
            while index < chars.count, !chars[index].isWhitespace, !"()[]\"'`".contains(chars[index]) {
                if chars[index] == "\\" { index = min(index + 1, chars.count) }
                if index < chars.count { index += 1 }
            }
            return index == objectStart ? min(index + 1, chars.count) : index
        }
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                index = min(index + 2, chars.count)
                continue
            }
            if char == "\"" {
                quoted.toggle()
                index += 1
                if !quoted && depth == 0 { break }
                continue
            }
            if !quoted {
                if char == "(" || char == "[" { depth += 1 }
                if char == ")" || char == "]" {
                    index += 1
                    depth -= 1
                    if depth <= 0 { break }
                    continue
                }
                if char.isWhitespace && depth == 0 { break }
            }
            index += 1
        }
        return index
    }

    /// The value as Emacs's reader takes it: `nil` is off and a whole number is a depth. Anything else is true,
    /// and so is a negative number, which Emacs does not take for a depth.
    private static func depth(_ value: String) -> OrgReadingDefaults.Depth {
        if value == "nil" || value == "()" { return .off }
        guard let levels = integer(value), levels >= 0 else { return .all }
        return levels == 0 ? .off : .levels(levels)
    }

    /// Lisp accepts decimal integers with a trailing dot, and #b, #o, #x or #Nr radix prefixes.
    private static func integer(_ value: String) -> Int? {
        var digits = value.lowercased()[...]
        var radix = 10
        if digits.first == "#" {
            digits.removeFirst()
            switch digits.first {
            case "b": radix = 2
            case "o": radix = 8
            case "x": radix = 16
            default:
                guard let marker = digits.firstIndex(of: "r"), let base = Int(digits[..<marker]),
                    (2...36).contains(base)
                else { return nil }
                radix = base
                digits = digits[marker...]
            }
            digits.removeFirst()
        } else if digits.last == "." {
            digits.removeLast()
        }
        let negative = digits.first == "-"
        if negative || digits.first == "+" { digits.removeFirst() }
        guard !digits.isEmpty else { return nil }
        var magnitude = 0
        for byte in digits.utf8 {
            let digit: Int
            switch byte {
            case 48...57: digit = Int(byte) - 48
            case 97...122: digit = Int(byte) - 97 + 10
            default: return nil
            }
            guard digit < radix else { return nil }
            magnitude = magnitude > (Int.max - digit) / radix ? Int.max : magnitude * radix + digit
        }
        return negative ? -magnitude : magnitude
    }

    func resolved(over settings: OrgReadingSettings) -> OrgReadingDefaults {
        settings.effectiveDefaults(file: file)
    }
}

/// The outline of one conversion: numbers, anchors and the entries of the tables of contents.
struct OrgOutline {
    struct Entry {
        /// 1 for the document's shallowest headline.
        let level: Int
        let escapedID: String
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
    var numbers = SectionNumbers()
    private var reservedCustomIDs: Set<String> = []
    private var usedIDs: Set<String> = []
    private var nextSuffix: [String: Int] = [:]
    /// `:UNNUMBERED:` values, each for the subtree of the headline at `level`.
    private var unnumbered: [(level: Int, value: String)] = []

    /// The nearest `:UNNUMBERED:` value that applies to a headline at `level` with these properties.
    mutating func unnumberedValue(level: Int, properties: [String: String]) -> String? {
        while let last = unnumbered.last, last.level >= level { unnumbered.removeLast() }
        if let value = properties["UNNUMBERED"] { unnumbered.append((level, value)) }
        guard let value = unnumbered.last?.value, value != "nil" else { return nil }
        return value
    }

    /// Keeps an id the document wrote itself away from the ids made here.
    mutating func reserve(_ id: String) {
        reservedCustomIDs.insert(id)
        usedIDs.insert(id)
    }

    mutating func customID(_ id: String) -> String {
        if reservedCustomIDs.remove(id) != nil { return id }
        return allocateID(id)
    }

    /// Keep the established heading stems, including the section prefix for a title that looks like a note ID.
    mutating func id(for text: String) -> String {
        let slug = MarkdownExtensions.slug(text.trimmingCharacters(in: .whitespaces))
        let base = slug.isEmpty ? "section" : (MarkdownExtensions.isNoteID(slug) ? "section-" + slug : slug)
        return allocateID(base)
    }

    /// All generated anchors share this namespace, including repeated footnote references.
    mutating func allocateID(_ base: String) -> String {
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

}

struct SectionNumbers {
    private var counters: [Int] = []

    private let start: Int
    init(start: Int = 1) { self.start = start }

    /// Org and Markdown retain skipped levels and a final dot. Computational documents use the compact form (1.2).
    mutating func next(level: Int, compact: Bool = false, trailingDot: Bool = true) -> String {
        if counters.isEmpty && level == 1 { counters.append(start - 1) }
        while counters.count < level { counters.append(0) }
        counters.removeLast(counters.count - level)
        counters[level - 1] += 1
        let components = compact ? counters.filter { $0 > 0 } : counters
        return Self.label(components.map(String.init), delimiter: ".", suffix: !compact && trailingDot ? "." : "")
    }

    /// Delegated readers can supply their native ordinals, including appendix letters and Roman part numbers.
    static func label(_ components: [String], delimiter: String, suffix: String) -> String {
        components.joined(separator: delimiter) + suffix
    }
}
