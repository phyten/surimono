import Foundation

// Counts byte inspections and the lengths submitted to bulk scans. Parser internals are covered by the
// depth preflight and wall-clock regression tests, not presented as measured cmark instructions.
struct ClipboardWork: Sendable {
    var steps = 0
    mutating func visit(_ count: Int = 1) { steps += count }
}

struct ClipboardWindow: Sendable {
    let bytes: [UInt8]
    let lines: [Range<Int>]
    let units: Int
    let truncated: Bool
    let broken: Bool
    let isBlank: Bool

    init(_ source: String) {
        // Native UTF-8 storage is borrowed, never copied in proportion to the entire clipboard.
        if let window = source.utf8.withContiguousStorageIfAvailable({ Self.scan($0) }) {
            self = window
        } else {
            // Three bounded phases, at most three UTF-8 bytes per UTF-16 unit, plus lookahead.
            let prefix = Array(source.utf8.prefix(3 * 3 * 32_768 + 4))
            self = prefix.withUnsafeBufferPointer { Self.scan($0) }
        }
    }

    private init(bytes: [UInt8], units: Int, truncated: Bool, broken: Bool, blank: Bool) {
        self.bytes = bytes
        var ranges: [Range<Int>] = []
        var first = 0
        for i in bytes.indices where bytes[i] == 10 {
            ranges.append(first..<i)
            first = i + 1
        }
        if first < bytes.count { ranges.append(first..<bytes.count) }
        lines = ranges
        self.units = units
        self.truncated = truncated
        self.broken = broken
        isBlank = blank
    }

    private static func scan(_ input: UnsafeBufferPointer<UInt8>) -> Self {
        func scalar(_ i: Int) -> (value: UInt32, width: Int) {
            let b = input[i]
            if b < 128 { return (UInt32(b), 1) }
            let width = b < 224 ? 2 : (b < 240 ? 3 : 4)
            var value = UInt32(b & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
            for j in 1..<width { value = (value << 6) | UInt32(input[i + j] & 63) }
            return (value, width)
        }
        func outside(_ start: Int) -> Bool {
            var i = start
            var units = 0
            while i < input.count && units < 32_768 {
                let s = scalar(i)
                if !white(s.value) { return true }
                units += s.value > 0xFFFF ? 2 : 1
                i += s.width
            }
            // An undecided suffix is truncated, never an unbounded whitespace scan.
            return i < input.count
        }
        var cursor = 0
        var lineStart = 0
        var skipped = 0
        while cursor < input.count && skipped < 32_768 {
            let s = scalar(cursor)
            if !white(s.value) { break }
            skipped += s.value > 0xFFFF ? 2 : 1
            cursor += s.width
            if s.value == 10 || s.value == 13 { lineStart = cursor }
        }
        if cursor == input.count || skipped >= 32_768 {
            return Self(
                bytes: [], units: 0, truncated: cursor < input.count, broken: false, blank: cursor == input.count)
        }
        cursor = lineStart
        let start = cursor
        var hasCR = false
        var count = 0
        var lineCount = 1
        var previousCR = false
        var damaged = false
        while cursor < input.count {
            let s = scalar(cursor)
            let width = s.value > 0xFFFF ? 2 : 1
            if count + width > 32_768 { break }
            let crlf = s.value == 10 && previousCR
            if !crlf && (s.value == 10 || s.value == 13) {
                if lineCount == 1_500 { break }
                lineCount += 1
            }
            count += width
            damaged = damaged || Self.damaged(s.value)
            if s.value == 13 { hasCR = true }
            previousCR = s.value == 13
            cursor += s.width
        }
        var bytes = Array(input[start..<cursor])
        if hasCR {
            var write = 0
            var cr = false
            for read in bytes.indices {
                let b = bytes[read]
                if b != 10 || !cr {
                    bytes[write] = b == 13 ? 10 : b
                    write += 1
                }
                cr = b == 13
            }
            bytes.removeSubrange(write..<bytes.count)
        }
        return Self(bytes: bytes, units: count, truncated: outside(cursor), broken: damaged, blank: false)
    }

    static func damaged(_ value: UInt32) -> Bool {
        value == 0xFFFD || value == 127 || (value < 32 && ![9, 10, 12, 13].contains(value))
    }

    static func white(_ value: UInt32) -> Bool {
        // Never classify forbidden controls as whitespace; they must enter the analysis window.
        if value < 128 { return value == 32 || value == 9 || value == 10 || value == 12 || value == 13 }
        if damaged(value) { return false }
        return value == 0xFEFF || Unicode.Scalar(value)?.properties.isWhitespace == true
    }

}

// A view into the shared UTF-8 window. Positions and slices remain integer byte offsets.
struct ClipboardSlice {
    let bytes: [UInt8]
    let range: Range<Int>
    init(_ bytes: [UInt8], _ range: Range<Int>? = nil) {
        self.bytes = bytes
        self.range = range ?? bytes.indices
    }
    var isEmpty: Bool { range.isEmpty }
    var count: Int { range.count }
    var first: UInt8? { range.isEmpty ? nil : bytes[range.lowerBound] }
    var string: String { String(decoding: bytes[range], as: UTF8.self) }
    func hasPrefix(_ text: String, folded: Bool = false) -> Bool {
        guard text.utf8.count <= range.count else { return false }
        var i = range.lowerBound
        for b in text.utf8 {
            let value = bytes[i]
            if (folded && (65...90).contains(value) ? value + 32 : value) != b { return false }
            i += 1
        }
        return true
    }
    func hasSuffix(_ text: String) -> Bool {
        guard text.utf8.count <= count else { return false }
        return ClipboardSlice(bytes, (range.upperBound - text.utf8.count)..<range.upperBound).hasPrefix(text)
    }
    func equals(_ text: String, folded: Bool = false) -> Bool {
        range.count == text.utf8.count && hasPrefix(text, folded: folded)
    }
    func contains(_ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, needle.count <= range.count else { return false }
        for i in range.lowerBound...(range.upperBound - needle.count) where bytes[i] == needle[0] {
            if bytes[i..<(i + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }
    func scalar(at index: Int) -> (value: UInt32, width: Int) {
        let b = bytes[index]
        if b < 128 { return (UInt32(b), 1) }
        let width = b < 224 ? 2 : (b < 240 ? 3 : 4)
        var value = UInt32(b & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
        for j in 1..<width { value = (value << 6) | UInt32(bytes[index + j] & 63) }
        return (value, width)
    }

    func wordEnd(from start: Int) -> Int {
        var end = start
        while end < range.upperBound {
            let s = scalar(at: end)
            if Unicode.Scalar(s.value)?.properties.isWhitespace == true { break }
            end += s.width
        }
        return end
    }

    var trimmed: Self {
        var lo = range.lowerBound
        var hi = range.upperBound
        // Non-ASCII whitespace is rare; decode only the boundary scalar, not the line.
        func whiteAt(_ i: Int, _ end: Int) -> Bool {
            if bytes[i] < 128 { return bytes[i] == 32 || (9...13).contains(bytes[i]) }
            var value = UInt32(bytes[i] & (end - i == 2 ? 31 : (end - i == 3 ? 15 : 7)))
            for j in (i + 1)..<end { value = (value << 6) | UInt32(bytes[j] & 63) }
            return value == 0xFEFF
                || Unicode.Scalar(value).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
        }
        while lo < hi {
            let b = bytes[lo]
            let end = min(hi, lo + (b < 128 ? 1 : (b < 224 ? 2 : (b < 240 ? 3 : 4))))
            if !whiteAt(lo, end) { break }
            lo = end
        }
        while hi > lo {
            var start = hi - 1
            while start > lo && bytes[start] & 192 == 128 { start -= 1 }
            if !whiteAt(start, hi) { break }
            hi = start
        }
        return Self(bytes, lo..<hi)
    }
}

enum ClipboardScanners {
    static let sourceLine =
        #"^(?:(?:export|public|private|static|async)\s+)*(?:(?:import\s+(?:[\w.]+(?:\s+from\s+|\s*$)|[\"'{*])|from\s+[\w.]+\s+import\s|using\s+[\w.]+\s*;|(?:def|func|function)\s+\w+\s*\([^)]*\)\s*(?:\{|:|->)|(?:class|struct|enum|interface)\s+\w+[^;]*\{|(?:if|for|while)\s*\(.+\)\s*\{|console\.\w+\s*\(|[\w$.-]+\s*(?:<-|:=)\s*\S|\$\w+\s*=\s*\S)|(?:/\*|\*/|//|\{-|--\[\[|@['\"]))"#
    static let configLine =
        #"^(?:(?:-\s+)?[\w.-]+:\s*(?:\S.*)?$|(?:FROM|RUN|CMD|COPY|ADD|WORKDIR|ENV|ARG|ENTRYPOINT|EXPOSE)\s+\S|[A-Z][a-z]+-[A-Z][\w-]+\s+-\w|(?:brew|make|swift|pdfinfo|lp|npm|yarn|pip|git|sudo|echo|cd|rm|mkdir|set|export)\s+\S|[.!*\w/-]+/$|[!.*][\w.*?/-]+$|\w+(?:\.\w+)*\([^)]*\)\s*$)"#
    static let dataLine =
        #"^(?:[\w$.-]+\s*(?:[?:+]?=|<-)\s*\S|(?:class|def|end|return|puts|print|assert|if|else|elif|for|while|try|except)\b|[\w.$]+\([^)]*\)(?:\.[\w().]+)*\s*$|[\w./~$]++[^;\r\n]*;[ \t]*$|[\w/~]++[^{}\r\n]*\{[ \t]*$|[{}]\s*$|\[[\w.-]+\]$|\$\s+(?:cd|git|make|npm)\b|\*/\d+\s+\*)"#
    static let yamlEntry = #"^(?:-\s+)?[\w.-]+:\s*(?:\S.*)?$"#
    static let cronLine = #"^(?:[\d*/,-]+\s+){5}\S"#
    static let markdownBlock =
        #"^(?:#{1,6}\s+|(?:[-+*]|\d+[.)])\s+|`{3,}|~{3,})|\*\*[^*]+\*\*|__[^_]+__|(?:^|\s)[*_]\S(?:[^*_\n]*\S)?[*_](?=\s|[.,!?]|$)"#
    static let logLine = #"^(?:\[(?:INFO|WARN|ERROR|DEBUG)\]|\[?\d{4}[-/]\d{2}[-/]\d{2}.*\d{2}:\d{2})"#
    static let htmlExpression = #"\{\s*[\w$]+(?:\.[\w$]+)*(?:\([^}]*\))?\s*\}"#

    private static let sourceWords: Set<String> = [
        "export", "public", "private", "static", "async", "import", "from", "using",
    ]
    private static let configWords: Set<String> = [
        "FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "ENTRYPOINT", "EXPOSE",
        "brew", "make", "swift", "pdfinfo", "lp", "npm", "yarn", "pip", "git", "sudo", "echo", "cd", "rm",
        "mkdir", "set", "export",
    ]
    private static let dataWords: Set<String> = [
        "class", "def", "end", "return", "puts", "print", "assert", "if", "else", "elif", "for", "while",
        "try", "except",
    ]

    private static let expressions: [String: NSRegularExpression] = {
        let patterns = [
            sourceLine, configLine, dataLine, yamlEntry, cronLine, markdownBlock, logLine, htmlExpression,
            #"^(#!|diff\s|@@\s|\*\*\*\s+\d|---\s+\d|\+\+\+ |--- [ab]/|\*\*\* [ab]/)"#,
            #"^#\+[a-zA-Z_]+:"#,
            #"^\*+\s+\S"#,
            #"^\*+\s+(TODO|DONE|NEXT|WAITING|CANCELLED)\b"#,
            #"^\*{2,}\s|^\*+\s+(TODO|DONE|NEXT|WAITING)\b|^(SCHEDULED|DEADLINE):"#,
            #"^[+$€£¥-]?\d{1,3}(?:,\d{2,3})+(?:\.\d+)?$"#,
            #"\b(?:Street|St\.?|Road|Rd\.?|Avenue|Ave\.?|Lane|Ln\.?|Drive|Dr\.?)\b"#,
        ]
        return Dictionary(uniqueKeysWithValues: patterns.map { ($0, try! NSRegularExpression(pattern: $0)) })
    }()

    // Regexes inspect at most 512 bytes. Whole-window tokens use the forward byte scanner below.
    static func matches(_ value: ClipboardSlice, _ pattern: String, work: inout ClipboardWork) -> Bool {
        let end = min(value.range.upperBound, value.range.lowerBound + 512)
        let bounded = ClipboardSlice(value.bytes, value.range.lowerBound..<end)
        if pattern == logLine {
            guard let first = bounded.first, first == 91 || (48...57).contains(first) else { return false }
        } else if pattern == sourceLine || pattern == configLine || pattern == dataLine {
            guard let first = bounded.first, first != 92 && first != 60 && first != 62 else { return false }
            var colon = false
            var equals = false
            var paren = false
            var brace = false
            var semicolon = false
            var hyphen = false
            var wordEnd = bounded.range.lowerBound
            for i in bounded.range {
                let byte = bounded.bytes[i]
                work.visit()
                if byte == 58 { colon = true }
                if byte == 61 { equals = true }
                if byte == 40 { paren = true }
                if byte == 123 || byte == 125 { brace = true }
                if byte == 59 { semicolon = true }
                if byte == 45 { hyphen = true }
                if wordEnd == i && byte != 32 && byte != 9 { wordEnd += 1 }
            }
            if first >= 128 && !colon && !equals && !paren && !brace && !semicolon && !hyphen { return false }
            let lead = ClipboardSlice(bounded.bytes, bounded.range.lowerBound..<wordEnd)
            let word = lead.string
            if pattern == sourceLine {
                let keyword = sourceWords.contains(word)
                let comment =
                    bounded.hasPrefix("/*") || bounded.hasPrefix("*/") || bounded.hasPrefix("//")
                    || bounded.hasPrefix("{-") || bounded.hasPrefix("--[[") || first == 64
                guard equals || paren || (colon && hyphen) || bounded.contains("<-") || keyword || comment else {
                    return false
                }
            } else if pattern == configLine {
                let command = configWords.contains(word)
                guard
                    colon || paren || bounded.hasSuffix("/") || [33, 46, 42].contains(first) || command
                        || ((65...90).contains(first) && hyphen)
                else { return false }
            } else {
                let keyword = dataWords.contains(word)
                guard
                    equals || paren || brace || semicolon || first == 91 || first == 36 || keyword
                        || bounded.contains("<-") || bounded.hasPrefix("*/")
                else { return false }
            }
        }
        let prefix = String(decoding: value.bytes[value.range.lowerBound..<end], as: UTF8.self)
        work.visit(end - value.range.lowerBound)
        return expressions[pattern]!.firstMatch(in: prefix, range: NSRange(location: 0, length: prefix.utf16.count))
            != nil
    }

    static func token(_ bytes: [UInt8], _ index: Int, _ token: [UInt8], folded: Bool = false, work: inout ClipboardWork)
        -> Bool
    {
        guard index + token.count <= bytes.count else { return false }
        for j in token.indices {
            work.visit()
            let b = bytes[index + j]
            if (folded && (65...90).contains(b) ? b + 32 : b) != token[j] { return false }
        }
        return true
    }

    static func unsafeText(_ bytes: [UInt8], range: Range<Int>? = nil, html: Bool = false, work: inout ClipboardWork)
        -> Bool
    {
        let bounds = range ?? bytes.indices
        var unsafe = false
        for i in bounds {
            work.visit()
            let b = bytes[i]
            let next: UInt8 = i + 1 < bounds.upperBound ? bytes[i + 1] : 0
            if b == 123 && (next == 123 || next == 37) { unsafe = true }
            if b == 60 && (next == 37 || next == 63 || next == 60) { unsafe = true }
        }
        if unsafe { return true }
        var cursor = bounds.lowerBound
        var declaration = 0
        while cursor < bounds.upperBound {
            work.visit()
            let byte = bytes[cursor]
            if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36 {
                let start = cursor
                while cursor < bounds.upperBound {
                    let next = bytes[cursor]
                    if !((65...90).contains(next) || (97...122).contains(next) || (48...57).contains(next) || next == 95
                        || next == 36)
                    {
                        break
                    }
                    cursor += 1
                    work.visit()
                }
                let word = ClipboardSlice(bytes, start..<cursor)
                if ["const", "let", "var", "my", "local", "def", "func", "function", "class", "struct"].contains(
                    where: { word.equals($0) })
                {
                    declaration = 1
                } else if declaration == 1 {
                    declaration = 2
                } else {
                    declaration = 0
                }
            } else {
                if declaration == 2 && (byte == 61 || byte == 123) { unsafe = true }
                if ![9, 10, 13, 32].contains(byte) { declaration = 0 }
                cursor += 1
            }
        }
        if unsafe { return true }
        var start = bounds.lowerBound
        for end in bounds.lowerBound...bounds.upperBound where end == bounds.upperBound || bytes[end] == 10 {
            let line = ClipboardSlice(bytes, start..<end).trimmed
            start = end + 1
            work.visit(line.count)
            guard !line.isEmpty else { continue }
            let diffLike =
                line.hasPrefix("#!") || line.hasPrefix("diff ") || line.hasPrefix("@@ ")
                || line.hasPrefix("*** ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            if diffLike
                && matches(line, #"^(#!|diff\s|@@\s|\*\*\*\s+\d|---\s+\d|\+\+\+ |--- [ab]/|\*\*\* [ab]/)"#, work: &work)
            {
                unsafe = true
            }
            if unsafe { return true }
            if matches(line, sourceLine, work: &work) { return true }
            if line.hasPrefix(String(repeating: "\"", count: 3)) || line.hasPrefix(String(repeating: "'", count: 3)) {
                unsafe = true
            }
            if html && (templateToken(line, work: &work) || matches(line, htmlExpression, work: &work)) {
                unsafe = true
            }
        }
        return unsafe
    }

    // Only an envelope anchored at the start and corroborated across the window may erase candidates.
    static func externalEnvelope(_ window: ClipboardWindow, work: inout ClipboardWork) -> Bool {
        let lines = window.lines.map { ClipboardSlice(window.bytes, $0).trimmed }.filter { !$0.isEmpty }
        guard let head = lines.first else { return false }
        work.visit(window.bytes.count)
        if head.hasPrefix("<?xml") || head.hasPrefix("<?php") || head.hasPrefix("#!")
            || head.hasPrefix("#[")
        {
            return true
        }
        let diffStart =
            head.hasPrefix("diff ") || head.hasPrefix("--- ") || head.hasPrefix("*** ")
            || head.hasPrefix("Index: ")
        if diffStart || head.hasPrefix("From ") {
            let unifiedHeader = lines.contains { $0.hasPrefix("--- ") } && lines.contains { $0.hasPrefix("+++ ") }
            let unifiedHunk = lines.contains { $0.hasPrefix("@@ -") && $0.contains(" +") && $0.contains(" @@") }
            let contextHunk =
                lines.contains { $0.equals("***************") }
                && lines.contains { $0.hasPrefix("*** ") && $0.hasSuffix(" ****") }
                && lines.contains { $0.hasPrefix("--- ") && $0.hasSuffix(" ----") }
            if diffStart
                && ((unifiedHeader && unifiedHunk)
                    || (contextHunk && head.hasPrefix("*** ") && !head.hasSuffix(" ****")))
            {
                return true
            }
            if head.hasPrefix("From ") && unifiedHeader && unifiedHunk { return true }
        }
        if head.hasPrefix("commit ") && lines.dropFirst().first?.hasPrefix("Author:") == true
            && lines.contains(where: { $0.hasPrefix("Date:") })
        {
            return true
        }
        if head.equals("転送されたメッセージ:") && lines.contains(where: { $0.hasPrefix("差出人:") })
            && lines.contains(where: { $0.hasPrefix("件名:") }) && lines.contains(where: { $0.hasPrefix("日付:") })
        {
            return true
        }
        if head.hasPrefix("From:") && lines.contains(where: { $0.hasPrefix("To:") })
            && lines.contains(where: { $0.hasPrefix("Subject:") })
        {
            return true
        }
        if head.hasPrefix("{\\rtf") && lines.last?.hasSuffix("}") == true { return true }
        if head.hasPrefix("@article{") || head.hasPrefix("@book{") || head.hasPrefix("@inproceedings{") {
            if lines.last?.equals("}") == true && lines.filter({ $0.contains("=") }).count >= 2 { return true }
        }
        if head.hasPrefix("<VirtualHost") && lines.last?.hasSuffix("</VirtualHost>") == true { return true }
        if head.hasPrefix("===") && head.contains("test session starts")
            && lines.last?.hasPrefix("===") == true
        {
            return true
        }
        if head.hasPrefix(";;;") && lines.contains(where: { $0.hasPrefix("(defun ") }) { return true }
        if head.equals("1") && lines.count >= 6 && lines[1].contains(" --> ")
            && lines.filter({ $0.contains(" --> ") }).count >= 2
        {
            return true
        }
        if head.hasPrefix("+") && head.contains("---+")
            && lines.filter({ $0.hasPrefix("+") && $0.contains("---+") }).count >= 2
            && lines.contains(where: { $0.hasPrefix("|") && $0.hasSuffix("|") })
        {
            return true
        }
        let content = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix(";") }
        if content.count >= 2 && content.allSatisfy({ matches($0, cronLine, work: &work) }) { return true }
        let logStart =
            matches(head, logLine, work: &work)
            || (head.hasPrefix("### ")
                && matches(
                    ClipboardSlice(window.bytes, (head.range.lowerBound + 4)..<head.range.upperBound), logLine,
                    work: &work))
        if logStart {
            let logs = lines.filter { matches($0, logLine, work: &work) }.count
            if logs >= 3 && logs * 2 > lines.count { return true }
        }
        if lines.contains(where: { $0.hasPrefix("```") || $0.hasPrefix("~~~") }) { return false }
        let anchored =
            head.hasPrefix("#") || head.hasPrefix(";") || matches(head, sourceLine, work: &work)
            || matches(head, configLine, work: &work) || matches(head, dataLine, work: &work)
        if anchored {
            let shaped = content.filter {
                matches($0, sourceLine, work: &work) || matches($0, configLine, work: &work)
                    || matches($0, dataLine, work: &work) || $0.hasSuffix("%>%")
            }.count
            if shaped >= 2 && shaped * 2 > content.count { return true }
        }
        if (head.equals("{") && lines.last?.equals("}") == true)
            || (head.equals("[") && lines.last?.equals("]") == true)
        {
            return true
        }
        return false
    }

    static func configDominates(_ bytes: [UInt8], original: [UInt8], lines: [Range<Int>], work: inout ClipboardWork)
        -> Bool
    {
        var total = 0
        var shaped = 0
        for range in lines {
            let line = ClipboardSlice(bytes, range).trimmed
            work.visit(range.count)
            let unmasked = ClipboardSlice(original, range).trimmed
            if unmasked.isEmpty || unmasked.hasPrefix("#") { continue }
            total += 1
            if matches(line, configLine, work: &work) || matches(line, sourceLine, work: &work)
                || matches(line, dataLine, work: &work)
            {
                shaped += 1
            }
        }
        return shaped >= 2 && shaped * 2 > total
    }

    static func url(_ window: ClipboardWindow, hints: ClipboardFormatHints, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var result = ClipboardCandidate(kind: .url)
        let span = ClipboardSlice(window.bytes).trimmed
        work.visit(window.bytes.count)
        guard span.hasPrefix("http://", folded: true) || span.hasPrefix("https://", folded: true) else { return result }
        result.structures = 1
        result.strength = 100
        result.evidence = [.links(1)]
        if hints.hasMatchingURL { result.evidence.append(.pasteboard) }
        let bytes = window.bytes
        var valid = true
        var units = 0
        var parentheses = 0
        var i = span.range.lowerBound
        while i < span.range.upperBound {
            work.visit()
            let b = bytes[i]
            let width = b < 128 ? 1 : (b < 224 ? 2 : (b < 240 ? 3 : 4))
            var value = UInt32(b)
            if width > 1 {
                value = UInt32(b & (width == 2 ? 31 : (width == 3 ? 15 : 7)))
                for j in 1..<width { value = (value << 6) | UInt32(bytes[i + j] & 63) }
            }
            units += value > 0xFFFF ? 2 : 1
            if let scalar = Unicode.Scalar(value),
                scalar.properties.isDefaultIgnorableCodePoint || scalar.properties.isWhitespace
                    || value < 32 || value == 127 || value == 60 || value == 62 || value == 92
            {
                valid = false
            }
            if b == 40 { parentheses += 1 }
            if b == 41 { parentheses -= 1 }
            if parentheses < 0 { valid = false }
            if b == 37 && (i + 2 >= span.range.upperBound || !hex(bytes[i + 1]) || !hex(bytes[i + 2])) { valid = false }
            i += width
        }
        valid = valid && units <= 8_192 && parentheses == 0
        // Foundation owns URL decomposition and IDNA; only this API boundary needs a String.
        let value = span.string
        if let components = URLComponents(string: value), let host = components.host, !host.isEmpty {
            valid = valid && components.scheme != nil && validHost(host)
            if let port = components.port, !(1...65_535).contains(port) { valid = false }
            if host.hasPrefix("[") && (!host.contains(":") || !host.hasSuffix("]")) { valid = false }
        } else {
            valid = false
        }
        result.ownsStart = valid
        result.accepted = valid
        result.sufficient = valid
        // Invalid URLs are text, not a document fragment needing a format question.
        if !valid { result.structures = 0 }
        return result
    }

    private static func validHost(_ host: String) -> Bool {
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            let body = host.dropFirst().dropLast()
            guard body.contains(":"), body.utf8.allSatisfy({ hex($0) || $0 == 58 || $0 == 46 }) else { return false }
            let groups = body.split(separator: ":", omittingEmptySubsequences: false)
            let nonempty = groups.filter { !$0.isEmpty }
            guard nonempty.allSatisfy({ $0.count <= 4 }), nonempty.count <= 8 else { return false }
            let compressions = body.components(separatedBy: "::").count - 1
            return compressions == 0 ? nonempty.count == 8 : compressions == 1 && nonempty.count < 8
        }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4 && labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
        return !labels.isEmpty
            && labels.allSatisfy { label in
                !label.isEmpty && label.first != "-" && label.last != "-"
                    && label.unicodeScalars.allSatisfy {
                        $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-"
                    }
            }
    }

    private static func hex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
