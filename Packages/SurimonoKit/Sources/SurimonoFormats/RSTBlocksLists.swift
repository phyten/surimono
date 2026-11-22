import Foundation

extension RSTBlockReader {
    struct Marker {
        let punctuation: String
        let kind: String
        let value: Int
        let prefix: Int
        let body: String

        var ordered: Bool { !kind.isEmpty }
    }

    func listMarker(_ line: String) -> Marker? {
        guard let first = line.first,
            "-*+•‣⁃(".contains(first) || first.isASCII && (first.isLetter || first.isNumber || first == "#")
        else { return nil }
        let token = line.prefix(while: { $0 != " " })
        guard !token.isEmpty, token.count <= 18 else { return nil }
        let rest = line[token.endIndex...]
        let body = rest.drop(while: { $0 == " " })
        let prefix = token.count + max(1, rest.prefix(while: { $0 == " " }).count)
        if token.count == 1, "-*+•‣⁃".contains(first) {
            return .init(punctuation: String(first), kind: "", value: 0, prefix: prefix, body: String(body))
        }
        guard let end = token.last, end == "." || end == ")" else { return nil }
        var digits = token.dropLast()
        var punctuation = String(end)
        if digits.first == "(" {
            guard end == ")" else { return nil }
            digits = digits.dropFirst()
            punctuation = "()"
        }
        guard !digits.isEmpty else { return nil }
        let value: Int
        let kind: String
        if digits == "#" {
            kind = "auto"
            value = 1
        } else if digits.allSatisfy(\.isNumber), let number = Int(digits), number > 0, number < Int.max {
            value = number
            kind = "arabic"
        } else if let initial = digits.first, initial.isASCII, initial.isLetter {
            let upper = initial.isUppercase
            let prefix = upper ? "upper" : "lower"
            if digits.count == 1, initial.lowercased() != "i", let ascii = initial.lowercased().utf8.first {
                kind = prefix + "alpha"
                value = Int(ascii) - 96
            } else {
                guard (upper ? digits.uppercased() : digits.lowercased()) == String(digits),
                    let number = Self.roman(digits.uppercased())
                else { return nil }
                kind = prefix + "roman"
                value = number
            }
        } else {
            return nil
        }
        return .init(punctuation: punctuation, kind: kind, value: value, prefix: prefix, body: String(body))
    }

    private static func roman(_ string: String) -> Int? {
        let units: [(String, Int)] = [
            ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400), ("C", 100), ("XC", 90), ("L", 50), ("XL", 40),
            ("X", 10), ("IX", 9), ("V", 5), ("IV", 4), ("I", 1),
        ]
        var rest = string[...]
        var number = 0
        for (text, value) in units {
            while rest.hasPrefix(text) {
                rest.removeFirst(text.count)
                number += value
            }
        }
        guard rest.isEmpty, number > 0, number < 5000 else { return nil }
        var canonical = ""
        var n = number
        for (text, value) in units {
            canonical += String(repeating: text, count: n / value)
            n %= value
        }
        return canonical == string ? number : nil
    }

    func startsList(_ marker: Marker) -> Bool {
        guard marker.ordered else { return true }
        // A lone initial and surname is common on a title page. Another item or an indented body
        // disambiguates an actual lettered list, including one with blank lines between items.
        if marker.kind == "upperalpha", marker.punctuation == ".", marker.body.first?.isUppercase == true,
            marker.body.dropFirst().allSatisfy(\.isLowercase)
        {
            var following = index + 1
            while following < lines.count, Self.blank(lines[following]) { following += 1 }
            guard following < lines.count else { return false }
            if lines[following].rstIndent >= marker.prefix { return true }
            return listMarker(lines[following]).map { continues(marker, with: $0, expected: marker.value + 1) } ?? false
        }
        guard index + 1 < lines.count else { return true }
        let next = lines[index + 1]
        if Self.blank(next) || next.rstIndent >= marker.prefix { return true }
        guard let nextMarker = listMarker(next) else { return false }
        return continues(marker, with: nextMarker, expected: marker.value + 1)
    }

    private func continues(_ first: Marker, with next: Marker, expected: Int) -> Bool {
        guard first.punctuation == next.punctuation else { return false }
        if !first.ordered { return !next.ordered }
        if next.kind == "auto" { return true }
        var other = next.value
        if first.kind != next.kind {
            // A single V or X may be an alphabetic marker in isolation, or part of a Roman sequence.
            guard first.kind.prefix(5) == next.kind.prefix(5) else { return false }
            if first.kind.hasSuffix("alpha"), next.kind.hasSuffix("roman"), next.value == 1 {
                other = 9
            } else if first.kind.hasSuffix("roman"), next.kind.hasSuffix("alpha"),
                let scalar = UnicodeScalar(64 + next.value), let value = Self.roman(String(scalar))
            {
                other = value
            } else {
                return false
            }
        }
        return other == expected
    }

    func list(_ first: Marker) -> String {
        let kind = first.kind == "auto" ? "arabic" : first.kind
        let type = ["loweralpha": "a", "upperalpha": "A", "lowerroman": "i", "upperroman": "I"][kind]
        let attrs = (type.map { " type=\"\($0)\"" } ?? "") + (first.value > 1 ? " start=\"\(first.value)\"" : "")
        var html = first.ordered ? "<ol\(attrs)>" : "<ul>"
        var next = first
        var value = first.value
        while true {
            index += 1
            var item = [next.body]
            let separated = index < lines.count && Self.blank(lines[index])
            let rest = indented(minimum: next.prefix, strip: next.prefix)
            if separated { item.append("") }
            item += rest
            html += "<li>\(document.blocks(item))</li>"
            guard index < lines.count, let candidate = listMarker(lines[index]), value < Int.max - 1,
                continues(first, with: candidate, expected: value + 1)
            else { break }
            next = candidate
            value += 1
        }
        return html + (first.ordered ? "</ol>" : "</ul>")
    }

    func field(_ line: String) -> (String, String)? {
        guard line.first == ":" else { return nil }
        var cursor = line.index(after: line.startIndex)
        let start = cursor
        while cursor < line.endIndex {
            let next = line.index(after: cursor)
            if line[cursor] == ":", cursor > start, next == line.endIndex || line[next] == " " {
                return (String(line[start..<cursor]), String(line[next...]).rstStripped)
            }
            cursor = next
        }
        return nil
    }

    func fields() -> [(String, String)] {
        var rows: [(String, String)] = []
        while index < lines.count, let (name, first) = field(lines[index]) {
            index += 1
            let separated = index < lines.count && Self.blank(lines[index])
            let content = document.blocks([first] + (separated ? [""] : []) + indented())
            rows.append((document.inline(name) + ":", content))
        }
        return rows
    }

    func option(_ line: String) -> (terms: String, description: String)? {
        guard let initial = line.first, "-+/".contains(initial), line.count > 1 else { return nil }
        let split = line.range(of: "  ")
        let terms = split.map { String(line[..<$0.lowerBound]) } ?? line
        let options = terms.components(separatedBy: ", ")
        for item in options {
            let name = item.prefix(while: { $0 != "=" && $0 != " " })
            let word = name.drop(while: { $0 == "-" || $0 == "+" || $0 == "/" })
            guard !word.isEmpty, name != word, word.first?.isLetter == true,
                word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                !item.dropFirst(name.count + 1).contains(" ")
            else { return nil }
        }
        if split == nil, !(index + 1 < lines.count && lines[index + 1].rstIndent > 0) { return nil }
        return (terms, split.map { String(line[$0.upperBound...]).rstStripped } ?? "")
    }

    func options() -> String {
        var html = "<dl class=\"option-list\">"
        while index < lines.count, let option = option(lines[index]) {
            index += 1
            let terms = option.terms.components(separatedBy: ", ").map { term -> String in
                guard let sep = term.firstIndex(where: { $0 == " " || $0 == "=" }) else { return HTML.escape(term) }
                let arg = term.index(after: sep)
                return HTML.escape(String(term[..<arg])) + "<var>\(HTML.escape(String(term[arg...])))</var>"
            }.joined(separator: ", ")
            html += "<dt><kbd>\(terms)</kbd></dt><dd>\(document.blocks([option.description] + indented()))</dd>"
        }
        return html + "</dl>"
    }
}

extension RSTDocument {
    /// Bibliographic fields have special shapes only at the front of the promoted document.
    func renderFields(_ rows: [(String, String)], docinfo: Bool) -> String {
        if !docinfo {
            return "<dl class=\"field-list\">" + rows.map { "<dt>\($0.0)</dt><dd>\($0.1)</dd>" }.joined() + "</dl>"
        }
        let known = [
            "author", "authors", "organization", "address", "contact", "version", "revision", "status", "date",
            "copyright",
        ]
        var table = ""
        var dedication = ""
        var abstract = ""
        for (label, body) in rows {
            let key = String(label.dropLast()).lowercased()
            if key == "abstract" || key == "dedication" {
                let topic = "<div class=\"topic \(key)\"><p class=\"topic-title\">\(key.capitalized)</p>\(body)</div>"
                if key == "dedication" { dedication += topic } else { abstract += topic }
                continue
            }
            let heading = known.contains(key) ? key.capitalized + ":" : label
            let value: String
            if key == "address", body.hasPrefix("<p>"), body.hasSuffix("</p>") {
                let address = body.dropFirst(3).dropLast(4).replacingOccurrences(of: "</p><p>", with: "\n\n")
                value = "<pre class=\"address\">\(address)</pre>"
            } else if key == "authors" {
                value = authorParagraphs(body)
            } else {
                value = body
            }
            table += "<tr><th>\(heading)</th><td>\(value)</td></tr>"
        }
        return (table.isEmpty ? "" : "<table class=\"docinfo\"><tbody>\(table)</tbody></table>") + dedication + abstract
    }

    private func authorParagraphs(_ body: String) -> String {
        if body.hasPrefix("<ul>"), body.hasSuffix("</ul>") {
            return String(body.dropFirst(4).dropLast(5)).replacingOccurrences(of: "<li>", with: "")
                .replacingOccurrences(of: "</li>", with: "")
        }
        guard body.hasPrefix("<p>"), body.hasSuffix("</p>") else { return body }
        let content = String(body.dropFirst(3).dropLast(4))
        // Split visible separators only; punctuation in a link destination belongs to the URL.
        let tokens = HTMLScanner.tokens(content)
        let separator =
            tokens.contains(where: {
                if case .text(let s) = $0 { return s.contains("; ") }
                return false
            }) ? "; " : ", "
        var result = "<p>"
        var depth = 0
        for token in tokens {
            switch token {
            case .tag(let tag):
                result += tag.source
                depth += tag.isClosing ? -1 : tag.isSelfClosing ? 0 : 1
            case .opaque(let text): result += text
            case .text(let text):
                result += depth == 0 ? text.replacingOccurrences(of: separator, with: "</p><p>") : text
            }
        }
        return result + "</p>"
    }
}
