import Foundation

/// The matches of Quarto and R Markdown's inline syntax in one line, left to right, as the alternation
///
///     (`+)(.*?)\1(?!`) | \$\$.*?\$\$ | \$[^$]+\$ | <[^>]+> | \]\([^)]+\) | \{\{<\s*(.*?)\s*>\}\}
///     | \^\[([^\]]+)\] | \[([^\]]*)\]\{([.\#][^}]+)\} | \\@ref\(([\w:.-]+)\) | \[(\-?)@([\w:.-]+)\]
///     | @([\w:-]+(?:\.[\w:-]+)*)
///
/// matched them, alternative by alternative and with the same lazy and greedy choices. A regular expression retried
/// every opening without its closer against the rest of the line: 20,000 `[` or 8,192 backticks took seconds. Here
/// each closer is found by a binary search in positions indexed once per line, so a line of n characters takes
/// O(n log n) time.
struct ComputationalInlineScanner {
    struct Match {
        var range: Range<Int>
        var code: Range<Int>?
        var shortcode: Range<Int>?
        var footnote: Range<Int>?
        var spanText: Range<Int>?
        var spanAttributes: Range<Int>?
        var bookdown: Range<Int>?
        var crossReferenceMinus: Range<Int>?
        var crossReference: Range<Int>?
        var bareReference: Range<Int>?

        init(_ range: Range<Int>) { self.range = range }
    }

    let characters: [Character]
    /// Sorted offsets of each closer the alternatives search for, of `$$` and `>}}`, and of line breaks.
    private let positions: [Character: [Int]]
    private let doubleDollars: [Int]
    private let shortcodeEnds: [Int]
    private let breaks: [Int]
    /// Backtick runs as (start, end), in order, and the longest later run on the same line as each run.
    private let runs: [(start: Int, end: Int)]
    private let longestAfter: [Int]

    init(_ text: String) {
        characters = Array(text)
        var positions: [Character: [Int]] = [:]
        var doubleDollars: [Int] = []
        var shortcodeEnds: [Int] = []
        var breaks: [Int] = []
        var runs: [(start: Int, end: Int)] = []
        var lines: [Int] = []
        for (offset, character) in characters.enumerated() {
            if ">)]}$".contains(character) { positions[character, default: []].append(offset) }
            if character.isNewline { breaks.append(offset) }
            if character == "$", offset + 1 < characters.count, characters[offset + 1] == "$" {
                doubleDollars.append(offset)
            }
            if character == ">", offset + 2 < characters.count, characters[offset + 1] == "}",
                characters[offset + 2] == "}"
            {
                shortcodeEnds.append(offset)
            }
            if character == "`" {
                if let last = runs.last, last.end == offset {
                    runs[runs.count - 1].end = offset + 1
                } else {
                    runs.append((offset, offset + 1))
                    lines.append(breaks.count)
                }
            }
        }
        self.positions = positions
        self.doubleDollars = doubleDollars
        self.shortcodeEnds = shortcodeEnds
        self.breaks = breaks
        self.runs = runs
        var longest = [Int](repeating: 0, count: runs.count)
        for index in stride(from: runs.count - 2, through: 0, by: -1) where lines[index + 1] == lines[index] {
            longest[index] = max(longest[index + 1], runs[index + 1].end - runs[index + 1].start)
        }
        longestAfter = longest
    }

    /// The first offset in `list` after `offset`.
    private static func first(in list: [Int], after offset: Int) -> Int? {
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low < list.count ? list[low] : nil
    }

    private func first(_ character: Character, after offset: Int) -> Int? {
        positions[character].flatMap { Self.first(in: $0, after: offset) }
    }

    /// Whether `range` holds no line break, as `.` does not match one.
    private func onOneLine(_ range: Range<Int>) -> Bool {
        guard let next = Self.first(in: breaks, after: range.lowerBound - 1) else { return true }
        return next >= range.upperBound
    }

    private func at(_ offset: Int) -> Character? { offset < characters.count ? characters[offset] : nil }

    /// `\w` of a regular expression over characters.
    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isSpace(_ character: Character) -> Bool { character.isWhitespace }

    func matches() -> [Match] {
        var matches: [Match] = []
        var offset = 0
        var runIndex = 0
        while offset < characters.count {
            while runIndex < runs.count, runs[runIndex].end <= offset { runIndex += 1 }
            if let match = match(at: offset, runIndex: runIndex) {
                matches.append(match)
                offset = match.range.upperBound
            } else {
                offset += 1
            }
        }
        return matches
    }

    private func match(at p: Int, runIndex: Int) -> Match? {
        switch characters[p] {
        case "`": return code(at: p, runIndex: runIndex)
        case "$": return math(at: p)
        case "<":
            guard let close = first(">", after: p), close >= p + 2 else { return nil }
            return Match(p..<(close + 1))
        case "]":
            guard at(p + 1) == "(", let close = first(")", after: p + 1), close >= p + 3 else { return nil }
            return Match(p..<(close + 1))
        case "{": return shortcode(at: p)
        case "^":
            guard at(p + 1) == "[", let close = first("]", after: p + 1), close >= p + 3 else { return nil }
            var match = Match(p..<(close + 1))
            match.footnote = (p + 2)..<close
            return match
        case "[": return span(at: p) ?? crossReference(at: p)
        case "\\": return bookdown(at: p)
        case "@": return bareReference(at: p)
        default: return nil
        }
    }

    /// `(`+)(.*?)\1(?!`)`: the longest opening that has a closing run of the same length followed by no backtick,
    /// and of those openings the earliest closing.
    private func code(at p: Int, runIndex: Int) -> Match? {
        guard runIndex < runs.count, runs[runIndex].start <= p else { return nil }
        let ownEnd = runs[runIndex].end
        let opening = ownEnd - p
        // An opening longer than half its own run can only close in a later run at least that long.
        let later = min(opening, longestAfter[runIndex])
        var length = 0
        var close = 0
        if later * 2 > opening {
            length = later
            // `longestAfter` promises such a run on this line.
            for index in (runIndex + 1)..<runs.count where runs[index].end - runs[index].start >= length {
                close = runs[index].end - length
                break
            }
        } else if opening >= 2 {
            length = opening / 2
            close = ownEnd - length
        } else {
            return nil
        }
        var match = Match(p..<(close + length))
        match.code = (p + length)..<close
        return match
    }

    /// `\$\$.*?\$\$` then `\$[^$]+\$`.
    private func math(at p: Int) -> Match? {
        if at(p + 1) == "$" {
            guard let close = Self.first(in: doubleDollars, after: p + 1), onOneLine((p + 2)..<close) else {
                return nil
            }
            return Match(p..<(close + 2))
        }
        guard let close = first("$", after: p), close >= p + 2 else { return nil }
        return Match(p..<(close + 1))
    }

    /// `\{\{<\s*(.*?)\s*>\}\}`: up to the first `>}}`, the contents without the spaces at either end.
    private func shortcode(at p: Int) -> Match? {
        guard at(p + 1) == "{", at(p + 2) == "<", let close = Self.first(in: shortcodeEnds, after: p + 2) else {
            return nil
        }
        // The spaces at either end may hold line breaks; the contents may not. A later `>}}` would keep the same
        // contents' ends, so only the first can match.
        var lower = p + 3
        while lower < close, Self.isSpace(characters[lower]) { lower += 1 }
        var upper = close
        while upper > lower, Self.isSpace(characters[upper - 1]) { upper -= 1 }
        guard onOneLine(lower..<upper) else { return nil }
        var match = Match(p..<(close + 3))
        match.shortcode = lower..<upper
        return match
    }

    /// `\[([^\]]*)\]\{([.\#][^}]+)\}`.
    private func span(at p: Int) -> Match? {
        guard let bracket = first("]", after: p), at(bracket + 1) == "{",
            let mark = at(bracket + 2), mark == "." || mark == "#",
            let brace = first("}", after: bracket + 2), brace >= bracket + 4
        else { return nil }
        var match = Match(p..<(brace + 1))
        match.spanText = (p + 1)..<bracket
        match.spanAttributes = (bracket + 2)..<brace
        return match
    }

    private func wordRun(from offset: Int, extra: String) -> Int {
        var end = offset
        while let character = at(end), Self.isWord(character) || extra.contains(character) { end += 1 }
        return end
    }

    /// `\[(\-?)@([\w:.-]+)\]`.
    private func crossReference(at p: Int) -> Match? {
        let minus = at(p + 1) == "-" && at(p + 2) == "@"
        let at = minus ? p + 2 : p + 1
        guard self.at(at) == "@" else { return nil }
        let end = wordRun(from: at + 1, extra: ":.-")
        guard end > at + 1, self.at(end) == "]" else { return nil }
        var match = Match(p..<(end + 1))
        match.crossReferenceMinus = minus ? (p + 1)..<(p + 2) : (p + 1)..<(p + 1)
        match.crossReference = (at + 1)..<end
        return match
    }

    /// `\\@ref\(([\w:.-]+)\)`.
    private func bookdown(at p: Int) -> Match? {
        guard Array("\\@ref(") == Array(characters[p..<min(characters.count, p + 6)]) else { return nil }
        let end = wordRun(from: p + 6, extra: ":.-")
        guard end > p + 6, at(end) == ")" else { return nil }
        var match = Match(p..<(end + 1))
        match.bookdown = (p + 6)..<end
        return match
    }

    /// `@([\w:-]+(?:\.[\w:-]+)*)`.
    private func bareReference(at p: Int) -> Match? {
        var end = wordRun(from: p + 1, extra: ":-")
        guard end > p + 1 else { return nil }
        while at(end) == ".", let next = at(end + 1), Self.isWord(next) || ":-".contains(next) {
            end = wordRun(from: end + 1, extra: ":-")
        }
        var match = Match(p..<end)
        match.bareReference = (p + 1)..<end
        return match
    }
}
