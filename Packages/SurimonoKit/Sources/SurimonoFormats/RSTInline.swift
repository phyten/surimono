import Foundation

/// The closing delimiters are indexed once. Retrying every potential opener against the rest of
/// the paragraph is quadratic for text such as a long series of unmatched opening asterisks.
private struct RSTInlineScanner {
    let document: RSTDocument
    let chars: [Character]
    var ends: [String: [Int]] = [:]
    var next: [String: Int] = [:]
    var followingBar: [Int: Int] = [:]

    init(_ source: String, document: RSTDocument) {
        self.document = document
        chars = Array(source)
        var i = 0
        var previousBar: Int?
        var nextCheck = 0
        while i < chars.count {
            if i >= nextCheck {
                if PreviewConversion.expired { return }
                nextCheck = i + 256
            }
            let char = chars[i]
            if char == "\\" {
                i += 2
                continue
            }
            if char == "|" {
                if let previousBar { followingBar[previousBar] = i }
                previousBar = i
            }
            if "*`|]".contains(char), i > 0, !chars[i - 1].isWhitespace {
                let double = (char == "*" || char == "`") && char == self[i + 1]
                let width = double ? 2 : 1
                let following = self[i + width]
                if Self.canEnd(following) || ("`|]".contains(char) && following == "_")
                    || (char == "`" && following == ":")
                {
                    ends[String(repeating: String(char), count: width), default: []].append(i)
                }
                if double { i += 1 }
            }
            i += 1
        }
    }

    private subscript(_ i: Int) -> Character? { chars.indices.contains(i) ? chars[i] : nil }
    fileprivate static func canStart(_ char: Character?) -> Bool {
        guard let char else { return true }
        if char.isASCII { return char.isWhitespace || "-:/'\"(<[{".contains(char) }
        return char.isWhitespace || unicodeSeparator(char, opening: true)
    }

    fileprivate static func canEnd(_ char: Character?) -> Bool {
        guard let char else { return true }
        if char.isASCII { return char.isWhitespace || "-.,:;!?\\/'\")]}>".contains(char) }
        return char.isWhitespace || unicodeSeparator(char, opening: false)
    }

    private static func unicodeSeparator(_ char: Character, opening: Bool) -> Bool {
        // Paired brackets have a direction; full stops, commas and quotation marks delimit either side.
        if "§¶".contains(char) { return false }
        if "„‚".contains(char) { return true }
        return char.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .openPunctuation: return opening
            case .closePunctuation: return !opening
            case .initialPunctuation, .finalPunctuation, .dashPunctuation, .otherPunctuation: return true
            default: return false
            }
        }
    }
    private static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "<": ">", "“": "”", "‘": "’", "«": "»", "‹": "›", "\"": "\"", "'": "'",
        "「": "」", "『": "』", "（": "）", "【": "】", "〈": "〉", "《": "》", "［": "］",
    ]

    private mutating func closing(_ key: String, after start: Int) -> Int? {
        guard let positions = ends[key] else { return nil }
        var index = next[key, default: 0]
        while index < positions.count, positions[index] <= start { index += 1 }
        next[key] = index
        return positions.indices.contains(index) ? positions[index] : nil
    }

    private func roleName(at position: Int) -> (name: String, end: Int)? {
        guard self[position] == ":" else { return nil }
        var i = position + 1
        var last: Int?
        while i - position <= 128, let c = self[i], c.isLetter || c.isNumber || "-_+:.".contains(c) {
            if c == ":" {
                last = i
                if self[i + 1] == "`" { break }
            }
            i += 1
        }
        guard let last, last > position + 1 else { return nil }
        return (String(chars[(position + 1)..<last]).lowercased(), last + 1)
    }

    mutating func render() -> String {
        var result = ""
        var start = 0
        var i = 0
        var nextCheck = 0
        while i < chars.count {
            if i >= nextCheck {
                if PreviewConversion.expired { return "" }
                nextCheck = i + 256
            }
            let char = chars[i]
            var end = i + 1
            var html: String?
            if char == "\\" {
                if let c = self[end] {
                    html = c.isWhitespace ? "" : HTML.escape(String(c))
                    end += 1
                }
            } else if Self.canStart(self[i - 1]) {
                if char == "[", let j = closing("]", after: i), self[j + 1] == "_", Self.canEnd(self[j + 2]) {
                    // A non-label can span arbitrarily many characters. Stop at its first invalid character.
                    var k = i + 1
                    while k < j, chars[k].isLetter || chars[k].isNumber || "-_.+#*".contains(chars[k]) { k += 1 }
                    if k == j, j > i + 1 {
                        let label = String(chars[(i + 1)..<j])
                        html = document.references.mark(.noteUse(label))
                        end = j + 2
                    }
                } else {
                    var open = i
                    var role: String?
                    let target = char == "_" && self[i + 1] == "`"
                    if target { open += 1 }
                    if char == ":", let prefix = roleName(at: i), self[prefix.end] == "`" {
                        open = prefix.end
                        role = prefix.name
                    }
                    let delimiter = chars[open]
                    if "*`|".contains(delimiter) {
                        let width = delimiter != "|" && self[open + 1] == delimiter ? 2 : 1
                        let key = String(repeating: String(delimiter), count: width)
                        let bodyStart = open + width
                        let quoted = self[i - 1].flatMap { Self.pairs[$0] }.map { $0 == self[bodyStart] } ?? false
                        let active = self[bodyStart].map { !$0.isWhitespace } == true && !quoted
                        if active, let j = closing(key, after: bodyStart - 1),
                            j > bodyStart, key != "|" || followingBar[open] == j
                        {
                            end = j + width
                            let raw = String(chars[bodyStart..<j])
                            let suffix = (self[end] == "_" ? (self[end + 1] == "_" ? 2 : 1) : 0)
                            switch key {
                            case "*", "**":
                                let tag = width == 2 ? "strong" : "em"
                                html = "<\(tag)>\(HTML.escape(RSTDocument.rstUnescape(raw)))</\(tag)>"
                            case "``": html = "<code>\(HTML.escape(raw))</code>"
                            case "|":
                                html = document.references.mark(.substitution(raw, suffix: suffix))
                                end += suffix
                            default:
                                if target {
                                    let text = RSTDocument.rstUnescape(raw)
                                    if document.references.checkingReplacement {
                                        document.references.invalidReplacement = true
                                        html = HTML.escape(text)
                                    } else {
                                        let id = document.references.id(text, kind: "target")
                                        document.references.targets[RSTReferences.name(text)] = .address("#" + id)
                                        html = "<span id=\"\(id)\">\(HTML.escape(text))</span>"
                                    }
                                } else if suffix > 0, role == nil {
                                    end += suffix
                                    html = document.rstPhraseLink(raw, anonymous: suffix == 2)
                                } else {
                                    if role == nil, let trailing = roleName(at: end) {
                                        role = trailing.name
                                        end = trailing.end
                                    }
                                    html = document.rstRole(role ?? document.references.defaultRole, raw: raw)
                                }
                            }
                        } else if active {
                            document.issueCount += 1
                            html = HTML.escape(String(chars[i..<bodyStart]))
                            end = bodyStart
                        }
                    }
                }
            }
            if let html {
                if start < i { result += document.rstPlain(String(chars[start..<i])) }
                result += html
                start = end
                i = end
            } else {
                i += 1
            }
        }
        if start < chars.count { result += document.rstPlain(String(chars[start...])) }
        return result
    }
}

extension RSTDocument {
    func inline(_ source: String) -> String {
        guard source.utf8.contains(where: { [42, 96, 124, 92, 91].contains($0) }) else { return rstPlain(source) }
        var scan = RSTInlineScanner(source, document: self)
        return scan.render()
    }

    static func rstUnescape(_ source: String) -> String {
        guard source.contains("\\") else { return source }
        var iterator = source.makeIterator()
        var text = ""
        while let c = iterator.next() {
            if c == "\\", let literal = iterator.next() {
                if !literal.isWhitespace { text.append(literal) }
            } else {
                text.append(c)
            }
        }
        return text
    }

    private static let addresses = WikiPattern(
        #"(?i)(?<![\p{L}\p{N}_])(?:(?:https?|ftp)://[^\s<>"']+|mailto:[^\s<>"']+|[A-Z0-9.!#$%&'*+/=?^_{}~\-]{1,64}@[A-Z0-9.\-]{1,253}\.[A-Z]{2,63})"#
    )

    fileprivate func rstPlain(_ source: String) -> String {
        guard source.contains("@") || source.contains("://") else { return rstSimpleNames(source) }
        return Self.addresses.replace(source, plain: rstSimpleNames) { match in
            let token = match[0]
            var url = token[...]
            var excess = token.reduce(0) { $0 + ($1 == ")" ? 1 : $1 == "(" ? -1 : 0) }
            while let last = url.last {
                if last == ")", excess > 0 { excess -= 1 } else if !".,;:!?。、「」".contains(last) { break }
                url = url.dropLast()
            }
            let address = String(url)
            let href = address.contains("@") && !address.contains(":") ? "mailto:" + address : address
            return rstLink(href, label: HTML.escape(address)) + HTML.escape(String(token.dropFirst(url.count)))
        }
    }

    private func rstSimpleNames(_ source: String) -> String {
        guard source.contains("_") else { return HTML.escape(source) }
        let chars = Array(source)
        var result = ""
        var cursor = 0
        var i = 0
        while i < chars.count {
            guard chars[i].isLetter || chars[i].isNumber else {
                i += 1
                continue
            }
            let start = i
            i += 1
            while i < chars.count {
                if chars[i].isLetter || chars[i].isNumber {
                    i += 1
                } else if "-._+:".contains(chars[i]), i + 1 < chars.count,
                    chars[i + 1].isLetter || chars[i + 1].isNumber
                {
                    i += 2
                } else {
                    break
                }
            }
            guard i < chars.count, chars[i] == "_", RSTInlineScanner.canStart(start == 0 ? nil : chars[start - 1])
            else { continue }
            let anonymous = i + 1 < chars.count && chars[i + 1] == "_"
            let end = i + (anonymous ? 2 : 1)
            guard RSTInlineScanner.canEnd(end < chars.count ? chars[end] : nil) else { continue }
            let name = String(chars[start..<i])
            result += HTML.escape(String(chars[cursor..<start]))
            result += rstNamedLink(
                name, label: HTML.escape(name), source: String(chars[start..<end]), anonymous: anonymous)
            i = end
            cursor = end
        }
        return result + HTML.escape(String(chars[cursor...]))
    }

    fileprivate func rstPhraseLink(_ raw: String, anonymous: Bool) -> String {
        let text = Self.rstUnescape(raw)
        let fallback = "`" + raw + (anonymous ? "`__" : "`_")
        if text.last == ">", let delimiter = text.lastIndex(of: "<") {
            let url = text[text.index(after: delimiter)..<text.index(before: text.endIndex)]
                .filter { !$0.isWhitespace }
            let caption = text[..<delimiter].trimmingCharacters(in: .whitespaces)
            let label = caption.isEmpty ? url : caption
            let target = rstTarget(url)
            if !anonymous {
                if references.checkingReplacement {
                    references.invalidReplacement = true
                } else {
                    references.targets[RSTReferences.name(label)] = target
                }
            }
            switch target {
            case .address(let href): return rstLink(href, label: HTML.escape(label))
            case .indirect(let name): return rstNamedLink(name, label: HTML.escape(label), source: fallback)
            }
        }
        return rstNamedLink(text, label: HTML.escape(text), source: fallback, anonymous: anonymous)
    }

    fileprivate func rstRole(_ name: String, raw: String) -> String {
        var kind = name
        var seen: Set<String> = []
        while let base = references.customRoles[kind], seen.count < 32, seen.insert(kind).inserted { kind = base }
        let text = Self.rstUnescape(raw)
        let escaped = HTML.escape(text)
        let tag: String
        switch kind {
        case "emphasis": tag = "em"
        case "strong": tag = "strong"
        case "literal", "code": tag = "code"
        case "sub", "subscript": tag = "sub"
        case "sup", "superscript": tag = "sup"
        case "title-reference", "title", "t": tag = "cite"
        case "math":
            return MathRenderer.html(raw, display: false)
                ?? (PreviewConversion.isActive ? MathRenderer.fallback(raw, display: false) : escaped)
        case "pep", "pep-reference", "rfc", "rfc-reference":
            guard let n = Int(text), n >= 0 else {
                issueCount += 1
                return escaped
            }
            if kind.hasPrefix("pep") {
                let digits = String(n)
                let suffix = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
                return rstLink("https://peps.python.org/pep-" + suffix, label: "PEP \(n)")
            }
            return rstLink("https://tools.ietf.org/html/rfc\(n).html", label: "RFC \(n)")
        case "ref", "doc", "term", "file", "kbd", "menuselection", "guilabel", "command", "program", "option", "envvar":
            return rstSphinxRole(kind, text: text)
        case "span": return escaped
        default:
            if kind.contains(":") { return rstSphinxRole(kind, text: text) }
            issueCount += 1
            return escaped
        }
        return "<\(tag)>\(escaped)</\(tag)>"
    }

    private func rstSphinxRole(_ kind: String, text: String) -> String {
        var label = text
        if text.last == ">", let split = text.lastIndex(of: "<") {
            label = text[..<split].trimmingCharacters(in: .whitespaces)
        } else if kind.contains(":"), text.first == "~" {
            label = String(text.dropFirst().split(separator: ".").last ?? "")
        }
        if kind.hasSuffix(":func") || kind.hasSuffix(":meth"), !label.hasSuffix("()") { label += "()" }
        if kind == "menuselection" { label = label.replacingOccurrences(of: "-->", with: "▸") }
        let safe = HTML.escape(label)
        switch kind {
        case "ref", "doc", "term", "guilabel", "menuselection": return safe
        case "kbd": return "<kbd>\(safe)</kbd>"
        default: return "<code>\(safe)</code>"
        }
    }
}
