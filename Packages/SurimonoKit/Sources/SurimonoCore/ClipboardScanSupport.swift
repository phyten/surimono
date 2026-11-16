import Foundation

// Counts byte inspections and the lengths submitted to bulk scans. Parser internals are covered by the
// depth preflight and wall-clock regression tests, not presented as measured cmark instructions.
struct ClipboardWork: Sendable {
    var steps = 0
    mutating func visit(_ count: Int = 1) { steps += count }
}

struct ClipboardWindow: Sendable {
    let text: String
    let bytes: [UInt8]
    let lines: [Range<Int>]
    let units: Int
    let truncated: Bool
    let broken: Bool
    let isBlank: Bool

    init(_ source: String) {
        let scalars = source.unicodeScalars
        var cursor = scalars.startIndex
        var lineStart = cursor
        var skipped = 0
        while cursor < scalars.endIndex && skipped < 32_768 {
            let scalar = scalars[cursor]
            guard Self.white(scalar.value) else { break }
            skipped += scalar.value > 0xFFFF ? 2 : 1
            cursor = scalars.index(after: cursor)
            if scalar == "\n" || scalar == "\r" { lineStart = cursor }
        }
        if cursor == scalars.endIndex || skipped >= 32_768 {
            text = ""
            bytes = []
            lines = []
            units = 0
            var outside = false
            while cursor < scalars.endIndex {
                if !Self.white(scalars[cursor].value) {
                    outside = true
                    break
                }
                cursor = scalars.index(after: cursor)
            }
            truncated = outside
            broken = false
            isBlank = true
            return
        }
        cursor = lineStart
        let start = cursor
        var count = 0
        var lineCount = 1
        var previousCR = false
        var damaged = false
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            let width = scalar.value > 0xFFFF ? 2 : 1
            if count + width > 32_768 { break }
            if scalar == "\n" && previousCR {
                // CRLF is one line boundary, but still consumes two UTF-16 units.
            } else if scalar == "\n" || scalar == "\r" {
                if lineCount == 1_500 { break }
                lineCount += 1
            }
            count += width
            damaged = damaged || Self.damaged(scalar.value)
            previousCR = scalar == "\r"
            cursor = scalars.index(after: cursor)
        }
        let end = cursor
        var outside = false
        while cursor < scalars.endIndex {
            if !Self.white(scalars[cursor].value) {
                outside = true
                break
            }
            cursor = scalars.index(after: cursor)
        }
        let raw = String(scalars[start..<end])
        text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        bytes = Array(text.utf8)
        var ranges: [Range<Int>] = []
        var first = 0
        for i in bytes.indices where bytes[i] == 10 {
            ranges.append(first..<i)
            first = i + 1
        }
        if first < bytes.count { ranges.append(first..<bytes.count) }
        lines = ranges
        units = count
        truncated = outside
        broken = damaged
        isBlank = false
    }

    static func damaged(_ value: UInt32) -> Bool {
        value == 0xFFFD || value == 127 || (value < 32 && ![9, 10, 12, 13].contains(value))
    }

    static func white(_ value: UInt32) -> Bool {
        // Never classify forbidden controls as whitespace; they must enter the analysis window.
        if damaged(value) { return false }
        return value == 0xFEFF || Unicode.Scalar(value)?.properties.isWhitespace == true
    }

    func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
}

enum ClipboardScanners {
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    // Regexes inspect at most 512 bytes. Whole-window tokens use the forward byte scanner below.
    static func matches(_ value: String, _ pattern: String, work: inout ClipboardWork) -> Bool {
        let prefix = String(decoding: value.utf8.prefix(512), as: UTF8.self)
        work.visit(prefix.utf8.count)
        return prefix.range(of: pattern, options: .regularExpression) != nil
    }

    static func token(_ bytes: [UInt8], _ index: Int, _ token: [UInt8], work: inout ClipboardWork) -> Bool {
        guard index + token.count <= bytes.count else { return false }
        for j in token.indices {
            work.visit()
            if bytes[index + j] != token[j] { return false }
        }
        return true
    }

    static func unsafeText(_ text: String, html: Bool = false, work: inout ClipboardWork) -> Bool {
        let bytes = Array(text.utf8)
        var unsafe = false
        for i in bytes.indices {
            work.visit()
            let b = bytes[i]
            let next: UInt8 = i + 1 < bytes.count ? bytes[i + 1] : 0
            if b == 123 && (next == 123 || next == 37 || html) { unsafe = true }
            if b == 60 && (next == 37 || next == 63 || next == 60) { unsafe = true }
        }
        var cursor = 0
        var declaration = 0
        var wantsCall = false
        while cursor < bytes.count {
            work.visit()
            let byte = bytes[cursor]
            if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36 {
                let start = cursor
                while cursor < bytes.count {
                    let next = bytes[cursor]
                    if !((65...90).contains(next) || (97...122).contains(next) || (48...57).contains(next) || next == 95
                        || next == 36)
                    {
                        break
                    }
                    cursor += 1
                    work.visit()
                }
                let word = String(decoding: bytes[start..<cursor], as: UTF8.self)
                if ["const", "let", "var", "my", "local", "def", "func", "function", "class", "struct"].contains(word) {
                    declaration = 1
                    wantsCall = ["def", "func", "function"].contains(word)
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
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = trimmed(String(raw))
            work.visit(raw.utf8.count)
            if matches(line, #"^(#!|diff\s|@@\s|\*\*\*\s+\d|---\s+\d|\+\+\+ |--- [ab]/|\*\*\* [ab]/)"#, work: &work) {
                unsafe = true
            }
            if matches(
                line,
                #"^(?:(?:export|public|private|static|async)\s+)*(?:(?:const|let|var|function|func|class|struct|enum|interface|import|from|def|return|console\.|if\s*\(|for\s*\(|while\s*\(|using|namespace|int\s|void\s|my\s|local\s)\b|[\w$.-]+\s*(?:=|:=)\s*\S)"#,
                work: &work)
            {
                unsafe = true
            }
            if matches(line, #"^(?:[\"']|@['\"]|/\*|\*/|//|\{-|--\[\[)|[;{}]\s*$"#, work: &work) {
                unsafe = true
            }
        }
        return unsafe
    }

    static func externalEnvelope(_ window: ClipboardWindow, work: inout ClipboardWork) -> Bool {
        let lines = window.lines
        guard let first = lines.first else { return false }
        let head = trimmed(window.string(first))
        if matches(
            head,
            #"^(?:diff |--- .*|\*\*\* .*|Index: |From: |From [0-9a-f]{12}|commit [0-9a-f]|Traceback |<\?xml|<\?php|<VirtualHost|##\[|\[?\d{4}[-/]\d{2}[-/]\d{2}.*(?:\d{2}:\d{2})|@(?:article|book)\{|#\[|#!)"#,
            work: &work)
        {
            return true
        }
        if head == "{" || head == "[" { return true }
        if matches(head, #"^(?:package [a-zA-Z_]|import |const |let |var |SELECT |[a-zA-Z_.]+ \{)$"#, work: &work) {
            return true
        }
        var logLines = 0
        for range in lines {
            let line = trimmed(window.string(range))
            work.visit(range.count)
            if matches(line, #"^\[(?:INFO|WARN|ERROR|DEBUG)\]"#, work: &work) { logLines += 1 }
        }
        return logLines >= 2
    }

    static func url(_ window: ClipboardWindow, hints: ClipboardFormatHints, work: inout ClipboardWork)
        -> ClipboardCandidate
    {
        var result = ClipboardCandidate(kind: .url)
        let value = trimmed(window.text)
        work.visit(window.bytes.count)
        let schemePrefix = value.prefix(8).lowercased()
        guard schemePrefix.hasPrefix("http://") || schemePrefix.hasPrefix("https://") else { return result }
        result.structures = 1
        result.strength = 100
        result.evidence = [.links(1)]
        if hints.hasMatchingURL { result.evidence.append(.pasteboard) }
        var valid = value.utf16.count <= 8_192
        for scalar in value.unicodeScalars {
            work.visit()
            if scalar.properties.isDefaultIgnorableCodePoint || scalar.properties.isWhitespace
                || scalar.value < 32 || scalar.value == 127 || scalar == "<" || scalar == ">" || scalar == "\\"
            {
                valid = false
            }
        }
        var parentheses = 0
        for byte in value.utf8 {
            work.visit()
            if byte == 40 { parentheses += 1 }
            if byte == 41 { parentheses -= 1 }
            if parentheses < 0 { valid = false }
        }
        if parentheses != 0 { valid = false }
        let bytes = Array(value.utf8)
        for i in bytes.indices where bytes[i] == 37 {
            work.visit()
            if i + 2 >= bytes.count || !hex(bytes[i + 1]) || !hex(bytes[i + 2]) { valid = false }
        }
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
