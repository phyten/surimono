import Foundation

/// A forward reader of HTML that knows where text ends and markup begins: a `>` inside a quoted attribute value does
/// not end its tag, and comments and the contents of raw text elements are not text. It reads bytes, as all the
/// characters it looks for are ASCII and a document can hold megabytes of embedded fonts.
struct HTMLScanner {
    enum Token: Equatable {
        case text(String)
        case tag(Tag)
        /// A comment, a declaration or the contents of a raw text element, to pass on as it is.
        case opaque(String)
    }

    struct Tag: Equatable {
        var source: String
        /// In lower case.
        var name: String
        var isClosing: Bool
        var isSelfClosing: Bool

        func attribute(_ wanted: String) -> String? { HTMLScanner.attribute(wanted, inTag: source) }
    }

    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]

    static func tokens(_ html: String) -> [Token] {
        let bytes = Array(html.utf8)
        var tokens: [Token] = []
        var textStart = 0
        var index = 0
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func flushText(upTo end: Int) {
            if textStart < end { tokens.append(.text(string(textStart..<end))) }
        }
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<"), let end = markupEnd(in: bytes, at: index) else {
                index += 1
                continue
            }
            flushText(upTo: index)
            guard let tag = tag(string(index..<end)) else {
                tokens.append(.opaque(string(index..<end)))
                index = end
                textStart = end
                continue
            }
            tokens.append(.tag(tag))
            index = end
            if !tag.isClosing, !tag.isSelfClosing, rawTextElements.contains(tag.name) {
                let close = closingTag(of: tag.name, in: bytes, from: index)
                if index < close { tokens.append(.opaque(string(index..<close))) }
                index = close
            }
            textStart = index
        }
        flushText(upTo: bytes.count)
        return tokens
    }

    /// The offset after the markup that starts at `start`, or nil when the `<` there is an ordinary character.
    private static func markupEnd(in bytes: [UInt8], at start: Int) -> Int? {
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
        var quote: UInt8?
        var index = nameStart
        while index < bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func tag(_ source: String) -> Tag? {
        guard source.hasPrefix("<"), !source.hasPrefix("<!"), !source.hasPrefix("<?") else { return nil }
        let isClosing = source.hasPrefix("</")
        let name = source.dropFirst(isClosing ? 2 : 1).prefix { $0.isLetter || $0.isNumber }.lowercased()
        return Tag(source: source, name: name, isClosing: isClosing, isSelfClosing: source.hasSuffix("/>"))
    }

    private static func closingTag(of name: String, in bytes: [UInt8], from start: Int) -> Int {
        let wanted = Array("</\(name)".utf8)
        var index = start
        while index + wanted.count <= bytes.count {
            if bytes[index] == UInt8(ascii: "<"),
                wanted.indices.allSatisfy({ lowercased(bytes[index + $0]) == wanted[$0] })
            {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    private static func offset(after text: String, in bytes: [UInt8], from start: Int) -> Int? {
        let count = text.utf8.count
        var index = start
        while index + count <= bytes.count {
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
        var rest = source.drop { !$0.isWhitespace && $0 != ">" }
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            guard let first = rest.first, first != ">" else { return nil }
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
            if name.lowercased() == wanted { return value }
            if name.isEmpty { rest = rest.dropFirst() }
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "times": "×",
    ]

    /// Decodes each character reference once, so `&amp;lt;` stays the text `&lt;`.
    static func decodingEntities(_ text: String) -> String {
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
