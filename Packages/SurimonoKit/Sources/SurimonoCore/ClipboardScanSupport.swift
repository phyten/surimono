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
            return Self(bytes: [], units: 0, truncated: outside(cursor), broken: false, blank: true)
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
    private static let expressions: [String: NSRegularExpression] = {
        let patterns = [
            #"^(#!|diff\s|@@\s|\*\*\*\s+\d|---\s+\d|\+\+\+ |--- [ab]/|\*\*\* [ab]/)"#,
            #"^(?:(?:export|public|private|static|async)\s+)*(?:(?:const|let|var|function|func|class|struct|enum|interface|import|from|def|return|console\.|if\s*\(|for\s*\(|while\s*\(|using|namespace|int\s|void\s|my\s|local\s)\b|[\w$.-]+\s*(?:=|:=)\s*\S)"#,
            #"^(?:[\"']|@['\"]|/\*|\*/|//|\{-|--\[\[)|[;{}]\s*$"#,
            #"^(?:diff |--- .*|\*\*\* .*|Index: |From: |From [0-9a-f]{12}|commit [0-9a-f]|Traceback |<\?xml|<\?php|<VirtualHost|##\[|\[?\d{4}[-/]\d{2}[-/]\d{2}.*(?:\d{2}:\d{2})|@(?:article|book)\{|#\[|#!)"#,
            #"^(?:package [a-zA-Z_]|import |const |let |var |SELECT |[a-zA-Z_.]+ \{)$"#,
            #"^\[(?:INFO|WARN|ERROR|DEBUG)\]"#,
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
            if b == 123 && (next == 123 || next == 37 || html) { unsafe = true }
            if b == 60 && (next == 37 || next == 63 || next == 60) { unsafe = true }
        }
        var cursor = bounds.lowerBound
        var declaration = 0
        var wantsCall = false
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
                    wantsCall = ["def", "func", "function"].contains(where: { word.equals($0) })
                } else if declaration == 1 {
                    declaration = 2
                } else {
                    declaration = 0
                }
            } else {
                if declaration == 2 && (byte == 61 || byte == 123 || (wantsCall && byte == 40)) { unsafe = true }
                if ![9, 10, 13, 32].contains(byte) { declaration = 0 }
                cursor += 1
            }
        }
        var start = bounds.lowerBound
        for end in bounds.lowerBound...bounds.upperBound where end == bounds.upperBound || bytes[end] == 10 {
            let line = ClipboardSlice(bytes, start..<end).trimmed
            start = end + 1
            work.visit(line.count)
            guard let first = line.first else { continue }
            if [35, 100, 64, 42, 45, 43].contains(first)
                && matches(line, #"^(#!|diff\s|@@\s|\*\*\*\s+\d|---\s+\d|\+\+\+ |--- [ab]/|\*\*\* [ab]/)"#, work: &work)
            {
                unsafe = true
            }
            let sourceLead = [
                "export", "public", "private", "static", "async", "const", "let", "var", "function", "func", "class",
                "struct", "enum", "interface", "import", "from", "def", "return", "console.", "if", "for", "while",
                "using", "namespace", "int", "void", "my", "local",
            ].contains { line.hasPrefix($0) }
            if (sourceLead || line.contains("="))
                && matches(
                    line,
                    #"^(?:(?:export|public|private|static|async)\s+)*(?:(?:const|let|var|function|func|class|struct|enum|interface|import|from|def|return|console\.|if\s*\(|for\s*\(|while\s*\(|using|namespace|int\s|void\s|my\s|local\s)\b|[\w$.-]+\s*(?:=|:=)\s*\S)"#,
                    work: &work)
            {
                unsafe = true
            }
            if ([34, 39, 42, 64, 47, 123, 45].contains(first) || line.contains(";") || line.contains("{")
                || line.contains("}"))
                && matches(line, #"^(?:[\"']|@['\"]|/\*|\*/|//|\{-|--\[\[)|[;{}]\s*$"#, work: &work)
            {
                unsafe = true
            }
        }
        return unsafe
    }

    static func externalEnvelope(_ window: ClipboardWindow, work: inout ClipboardWork) -> Bool {
        let lines = window.lines
        guard let first = lines.first else { return false }
        let head = ClipboardSlice(window.bytes, first).trimmed
        if matches(
            head,
            #"^(?:diff |--- .*|\*\*\* .*|Index: |From: |From [0-9a-f]{12}|commit [0-9a-f]|Traceback |<\?xml|<\?php|<VirtualHost|##\[|\[?\d{4}[-/]\d{2}[-/]\d{2}.*(?:\d{2}:\d{2})|@(?:article|book)\{|#\[|#!)"#,
            work: &work)
        {
            return true
        }
        if head.equals("{") || head.equals("[") { return true }
        if matches(head, #"^(?:package [a-zA-Z_]|import |const |let |var |SELECT |[a-zA-Z_.]+ \{)$"#, work: &work) {
            return true
        }
        var logLines = 0
        for range in lines {
            let line = ClipboardSlice(window.bytes, range).trimmed
            work.visit(range.count)
            if line.first == 91 && matches(line, #"^\[(?:INFO|WARN|ERROR|DEBUG)\]"#, work: &work) { logLines += 1 }
        }
        return logLines >= 2
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
