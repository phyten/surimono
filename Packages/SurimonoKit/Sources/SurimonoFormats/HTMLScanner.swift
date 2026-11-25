import Foundation

/// A forward reader of HTML that knows where text ends and markup begins: a `>` inside a quoted attribute value does
/// not end its tag, and comments and the contents of raw text elements are not text. It reads bytes, as all the
/// characters it looks for are ASCII and a document can hold megabytes of embedded fonts.
package struct HTMLScanner {
    package enum Token: Equatable {
        case text(String)
        case tag(Tag)
        /// A comment, a declaration or the contents of a raw text element, to pass on as it is.
        case opaque(String)
    }

    package struct Tag: Equatable {
        package var source: String
        /// In lower case.
        package var name: String
        package var isClosing: Bool
        package var isSelfClosing: Bool

        package func attribute(_ wanted: String) -> String? { HTMLScanner.attribute(wanted, inTag: source) }
    }

    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    package static func tokens(_ html: String) -> [Token] {
        var tokens: [Token] = []
        forEachToken(html) { tokens.append($0) }
        return tokens
    }

    /// Visits large fragments without retaining a second copy of every token.
    package static func forEachToken(_ html: String, visit: (Token) throws -> Void) rethrows {
        let bytes = Array(html.utf8)
        var textStart = 0
        var index = 0
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        var tagEnds = TagEnds(bytes)
        var nextCheck = 0
        while index < bytes.count {
            if index >= nextCheck {
                if PreviewConversion.expired { return }
                nextCheck = index + 4096
            }
            guard bytes[index] == UInt8(ascii: "<"), let end = markupEnd(in: bytes, at: index, tagEnds: &tagEnds)
            else {
                index += 1
                continue
            }
            if textStart < index { try visit(.text(string(textStart..<index))) }
            guard let tag = tag(string(index..<end)) else {
                try visit(.opaque(string(index..<end)))
                index = end
                textStart = end
                continue
            }
            try visit(.tag(tag))
            index = end
            if !tag.isClosing, !tag.isSelfClosing, rawTextElements.contains(tag.name) {
                let close = closingTag(of: tag.name, in: bytes, from: index)
                if index < close { try visit(.opaque(string(index..<close))) }
                index = close
            }
            textStart = index
        }
        if textStart < bytes.count { try visit(.text(string(textStart..<bytes.count))) }
    }

    /// Where a tag that starts scanning at an offset ends. Scanning forward from every `<` is quadratic when the
    /// tags never end (`<a <a <a …`, 30 KB took seconds). A scan is a walk whose next step depends only on the offset
    /// and whether it is inside a `"` or `'` quote, so two walks that reach the same offset in the same state end
    /// alike. After the first walk that runs off the end, every offset and state a failed walk passed is marked, and
    /// a later walk that reaches a mark stops there: each offset is passed at most three times by failed walks, and
    /// a walk that ends moves the reader past everything it passed. The marks take a byte per byte after that first
    /// tag; ordinary pages, whose tags end, never make them.
    struct TagEnds {
        let bytes: [UInt8]
        let lastGreater: Int
        /// From `base` on, a bit per quote state (none, `"`, `'`) in which a walk at that offset finds no end.
        private var failed: [UInt8] = []
        private var base = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
            lastGreater = bytes.lastIndex(of: UInt8(ascii: ">")) ?? -1
        }

        /// The offset after the `>` that ends a tag whose name starts at `start`, or nil when none does.
        mutating func end(from start: Int) -> Int? {
            guard start <= lastGreater else { return nil }
            // Until a tag runs off the end there are no marks: a plain forward scan, as fast as it ever was.
            if failed.isEmpty, let end = Self.scan(bytes, from: start) { return end }
            if !failed.isEmpty, let end = walk(from: start, marking: false) { return end }
            if failed.isEmpty {
                base = start
                failed = [UInt8](repeating: 0, count: bytes.count - start)
            }
            // The same walk again, marking what it passes; it stops where the first one did.
            _ = walk(from: start, marking: true)
            return nil
        }

        private static func scan(_ bytes: [UInt8], from start: Int) -> Int? {
            bytes.withUnsafeBufferPointer { buffer in
                var quote: UInt8 = 0
                var index = start
                while index < buffer.count {
                    if index.isMultiple(of: 4096), PreviewConversion.expired { return nil }
                    let byte = buffer[index]
                    if quote != 0 {
                        if byte == quote { quote = 0 }
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: ">") {
                        return index + 1
                    }
                    index += 1
                }
                return nil
            }
        }

        private mutating func walk(from start: Int, marking: Bool) -> Int? {
            var quote: UInt8 = 0
            var index = start
            while index < bytes.count {
                if index.isMultiple(of: 4096), PreviewConversion.expired { return nil }
                if !failed.isEmpty, index >= base {
                    let bit: UInt8 = quote == 0 ? 1 : quote == UInt8(ascii: "\"") ? 2 : 4
                    if failed[index - base] & bit != 0 { return nil }
                    if marking { failed[index - base] |= bit }
                }
                let byte = bytes[index]
                if quote != 0 {
                    if byte == quote { quote = 0 }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    return index + 1
                }
                index += 1
            }
            return nil
        }
    }

    /// The offset after the markup that starts at `start`, or nil when the `<` there is an ordinary character.
    private static func markupEnd(in bytes: [UInt8], at start: Int, tagEnds: inout TagEnds) -> Int? {
        let next = start + 1
        guard next < bytes.count else { return nil }
        if matches("<!--", in: bytes, at: start) {
            return offset(after: "-->", in: bytes, from: start + 4) ?? bytes.count
        }
        if bytes[next] == UInt8(ascii: "!") || bytes[next] == UInt8(ascii: "?") {
            return offset(after: ">", in: bytes, from: next) ?? bytes.count
        }
        let nameStart = bytes[next] == UInt8(ascii: "/") ? next + 1 : next
        guard nameStart < bytes.count, isLetter(bytes[nameStart]) else { return nil }
        return tagEnds.end(from: nameStart)
    }

    private static func tag(_ source: String) -> Tag? {
        guard source.hasPrefix("<"), !source.hasPrefix("<!"), !source.hasPrefix("<?") else { return nil }
        let isClosing = source.hasPrefix("</")
        let name = source.dropFirst(isClosing ? 2 : 1).prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            .lowercased()
        return Tag(source: source, name: name, isClosing: isClosing, isSelfClosing: source.hasSuffix("/>"))
    }

    private static func closingTag(of name: String, in bytes: [UInt8], from start: Int) -> Int {
        let wanted = Array("</\(name)".utf8)
        var index = start
        while index + wanted.count <= bytes.count {
            if index.isMultiple(of: 4096), PreviewConversion.expired { return bytes.count }
            if bytes[index] == UInt8(ascii: "<"),
                wanted.indices.allSatisfy({ lowercased(bytes[index + $0]) == wanted[$0] }),
                index + wanted.count == bytes.count || endsTagName(bytes[index + wanted.count])
            {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    private static func endsTagName(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: " ") || (9...13).contains(byte)
    }

    private static func offset(after text: String, in bytes: [UInt8], from start: Int) -> Int? {
        let count = text.utf8.count
        var index = start
        while index + count <= bytes.count {
            if index.isMultiple(of: 4096), PreviewConversion.expired { return nil }
            if matches(text, in: bytes, at: index) { return index + count }
            index += 1
        }
        return nil
    }

    private static func matches(_ text: String, in bytes: [UInt8], at start: Int) -> Bool {
        let wanted = Array(text.utf8)
        guard start + wanted.count <= bytes.count else { return false }
        return wanted.indices.allSatisfy { bytes[start + $0] == wanted[$0] }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func attribute(_ wanted: String, inTag source: String) -> String? {
        var found: String?
        visitAttributes(in: source) { name, value in
            guard name == wanted else { return true }
            found = decodingEntities(value)
            return false
        }
        return found
    }

    /// The visitor can stop after the first matching attribute. Values still contain HTML entities.
    package static func visitAttributes(in source: String, visit: (String, String) -> Bool) {
        var rest = source.drop { !$0.isWhitespace && $0 != ">" }
        while true {
            if PreviewConversion.expired { return }
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            guard let first = rest.first, first != ">" else { return }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != ">" && $0 != "/" }
            rest = rest.dropFirst(name.count).drop(while: \.isWhitespace)
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let inside = rest.dropFirst()
                    let body = inside.prefix { $0 != quote }
                    value = String(body)
                    rest = inside.dropFirst(body.count + 1)
                } else {
                    let body = rest.prefix { !$0.isWhitespace && $0 != ">" }
                    value = String(body)
                    rest = rest.dropFirst(body.count)
                }
            }
            if !visit(name.lowercased(), value) { return }
            if name.isEmpty { rest = rest.dropFirst() }
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "times": "×",
    ]

    /// Decodes each character reference once, so `&amp;lt;` stays the text `&lt;`.
    package static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = text[...]
        while let ampersand = rest.firstIndex(of: "&") {
            output += rest[..<ampersand]
            rest = rest[ampersand...]
            let body = rest.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "#" }
            let end = rest.index(rest.startIndex, offsetBy: body.count + 1)
            guard end < rest.endIndex, rest[end] == ";", let value = entityValue(String(body)) else {
                output.append("&")
                rest = rest.dropFirst()
                continue
            }
            output += value
            rest = rest[rest.index(after: end)...]
        }
        return output + rest
    }

    private static func entityValue(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return namedEntities[body] }
        let digits = body.dropFirst()
        let isHex = digits.first == "x" || digits.first == "X"
        guard let code = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10),
            let scalar = Unicode.Scalar(code)
        else { return nil }
        return String(Character(scalar))
    }
}
