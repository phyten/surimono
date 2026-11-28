import Foundation

/// A BibTeX field is a sequence of literals and previously defined strings. Parse at delimiter depth,
/// since a comma, quote or closing parenthesis in a protected title is ordinary text.
struct LaTeXBibTeX {
    private let input: [Character]
    private var cursor = 0
    private let document: LaTeXDocument

    init(_ source: String, document: LaTeXDocument) {
        input = Array(source)
        self.document = document
    }

    private var next: Character? { cursor < input.count ? input[cursor] : nil }

    private mutating func take(_ character: Character) -> Bool {
        guard next == character else { return false }
        cursor += 1
        return true
    }

    private mutating func skipSpace() {
        while let character = next {
            if character.isWhitespace {
                cursor += 1
            } else if character == "%" {
                while let c = next, c != "\n" { cursor += 1 }
            } else {
                return
            }
        }
    }

    private mutating func token() -> String {
        skipSpace()
        let start = cursor
        while let c = next, !c.isWhitespace, !"{},()=\"#%@".contains(c) { cursor += 1 }
        return String(input[start..<cursor])
    }

    /// Walk balanced literals iteratively, so a malformed brace sequence cannot exhaust the call stack.
    private mutating func literal(close: Character, open: Character = "{") -> String {
        let start = cursor
        var depth = 0
        while let c = next {
            cursor += 1
            if c == "\\" {
                if next != nil { cursor += 1 }
            } else if c == close, depth == 0 {
                return String(input[start..<(cursor - 1)])
            } else if c == open {
                depth += 1
                if depth > LaTeXDocument.maximumDepth {
                    document.stopExpanding(.depth)
                    return ""
                }
            } else if c == (open == "(" ? ")" : "}"), depth > 0 {
                depth -= 1
            }
        }
        return String(input[start..<cursor])
    }

    private mutating func value() -> String {
        var result = ""
        repeat {
            skipSpace()
            if take("{") {
                result += literal(close: "}")
            } else if take("\"") {
                result += literal(close: "\"")
            } else {
                let key = token()
                if let expansion = document.bibDatabase.expansion(of: key.lowercased()) {
                    // Reusing a long @string many times can grow a tiny database exponentially.
                    guard document.reserveExpansion(characters: expansion.utf8.count) else { return result }
                    result += expansion
                } else {
                    result += key
                }
            }
            skipSpace()
        } while take("#") && !document.stopsExpanding
        return result
    }

    mutating func parse() {
        while let c = next, !document.stopsExpanding {
            if c == "%" {
                skipSpace()
                continue
            }
            cursor += 1
            guard c == "@" else { continue }
            let type = token().lowercased()
            skipSpace()
            let close: Character
            if take("{") { close = "}" } else if take("(") { close = ")" } else { continue }
            if type == "comment" || type == "preamble" {
                _ = literal(close: close, open: close == ")" ? "(" : "{")
                continue
            }
            guard document.reserveExpansion() else { return }
            let key = token()
            skipSpace()
            if type == "string" {
                if take("=") {
                    let text = value()
                    document.bibDatabase.strings[key.lowercased()] = text
                }
                continue
            }
            guard !key.isEmpty, take(",") else { continue }
            var fields: [String: String] = [:]
            while !document.stopsExpanding {
                let name = token().lowercased()
                skipSpace()
                guard !name.isEmpty, take("=") else { break }
                fields[name] = value()
                if !take(",") { break }
            }
            if document.bibDatabase.records[key] == nil {
                document.bibDatabase.records[key] = .init(type: type, fields: fields)
                document.bibDatabase.fileOrder.append(key)
            }
        }
    }
}

/// Bibliographic fields are data, including when they contain TeX escapes. Decode text accents and
/// ligatures without running document commands (a title must not be able to change counters or read files).
enum LaTeXBibText {
    static func decode(_ source: String, html: Bool = false, sentenceCase: Bool = false) -> String {
        let chars = Array(source)
        var text = ""
        var markedUp = ""
        func flushText() {
            markedUp += html ? HTML.escape(text) : text
            text.removeAll(keepingCapacity: true)
        }
        var i = 0
        var depth = 0
        var keepInitial = true
        func append(_ piece: String) {
            guard !piece.isEmpty else { return }
            let displayed = sentenceCase && depth == 0 && !keepInitial ? piece.lowercased() : piece
            text += displayed
            if piece.contains(where: { !$0.isWhitespace }) { keepInitial = piece == ":" }
        }
        while i < chars.count {
            let c = chars[i]
            i += 1
            switch c {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "~": text += " "
            case "\\" where i < chars.count:
                let start = i
                i += 1
                if chars[start].isASCII && chars[start].isLetter {
                    while i < chars.count && chars[i].isASCII && chars[i].isLetter { i += 1 }
                }
                let name = String(chars[start..<i])
                if name.count == 1, let mark = LaTeXSymbols.accents[chars[start]] {
                    while i < chars.count && (chars[i] == "{" || chars[i].isWhitespace) {
                        if chars[i] == "{" { depth += 1 }
                        i += 1
                    }
                    if i + 1 < chars.count, chars[i] == "\\", "ij".contains(chars[i + 1]) { i += 1 }
                    if i < chars.count {
                        append(String(chars[i]) + String(mark))
                        i += 1
                    }
                } else if html, let logo = LaTeXSymbols.logoHTML(name) {
                    flushText()
                    markedUp += logo
                    keepInitial = false
                } else if let symbol = LaTeXSymbols.text[name] {
                    append(symbol)
                } else if name.count == 1 {
                    append(LaTeXSymbols.controlSymbols[chars[start]] ?? name)
                }
            default: append(String(c))
            }
        }
        flushText()
        return markedUp.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    /// "and" inside a braced organization name is part of its name.
    static func names(_ source: String) -> [(family: String, printedHTML: String)] {
        var parts: [String] = []
        var words: [Substring] = []
        var depth = 0
        for word in source.split(whereSeparator: \.isWhitespace) {
            if depth == 0 && word.lowercased() == "and" {
                parts.append(words.joined(separator: " "))
                words.removeAll(keepingCapacity: true)
            } else {
                words.append(word)
                for c in word {
                    if c == "{" { depth += 1 }
                    if c == "}" { depth = max(0, depth - 1) }
                }
            }
        }
        parts.append(words.joined(separator: " "))
        return parts.filter { !$0.isEmpty }.map { raw in
            if raw.hasPrefix("{") && raw.hasSuffix("}") { return (decode(raw), decode(raw, html: true)) }
            if raw.lowercased() == "others" { return ("et al.", "et al.") }
            let parts = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let words = raw.split(separator: " ")
            let family = parts.count > 1 ? parts[0] : String(words.last ?? "")
            let given = parts.count > 1 ? (parts.last ?? "") : words.dropLast().joined(separator: " ")
            let suffix = parts.count > 2 ? ", " + parts[1] : ""
            let printName = [given, family].filter { !$0.isEmpty }.joined(separator: " ") + suffix
            return (decode(family), decode(printName, html: true))
        }
    }
}
