import Foundation

public enum SyntaxHighlighter {
    // Bound allocations and conversion latency before creating the indexed scalar buffer.
    private static let maximumUTF16Count = 200_000

    /// HTML with tokens wrapped in spans, or nil for an unknown language or code too large to highlight.
    public static func highlight(_ code: String, language: String) -> String? {
        guard code.utf16.count <= maximumUTF16Count, let id = canonicalLanguage(for: language) else { return nil }
        var scanner = SyntaxScanner(code, language: SyntaxLanguage.definition(id))
        return scanner.render()
    }

    /// The canonical id for a fence info string such as "JS", "c++" or "swift title=a.swift".
    public static func canonicalLanguage(for infoString: String) -> String? {
        let name = infoString.prefix { !$0.isWhitespace && $0 != "{" && $0 != "," }.lowercased()
        return SyntaxLanguage.aliases[name]
    }
}

private struct SyntaxScanner: Sendable {
    let source: [Unicode.Scalar]
    let language: SyntaxLanguage
    // Cached lookahead prevents repeated scans of long whitespace suffixes.
    let nextContent: [Int]
    let lineEnds: [Int]
    let rawClosingHashes: [Int]
    let tripleClosingHashes: [Int]
    var index = 0
    var lineStart = 0
    var cssDepth = 0
    var inTag = false
    var wantsTagName = false
    var closingTag = false
    var wantsAttributeValue = false
    var rawTag: String?
    // Failed multiline searches cover the suffix for this delimiter, keeping recovery linear.
    var exhaustedStrings: Set<String> = []
    var output = ""

    init(_ code: String, language: SyntaxLanguage) {
        let scalars = Array(code.unicodeScalars)
        source = scalars
        self.language = language
        var content = Array(repeating: scalars.count, count: scalars.count + 1)
        var ends = content
        for i in scalars.indices.reversed() {
            content[i] = CharacterSet.whitespacesAndNewlines.contains(scalars[i]) ? content[i + 1] : i
            ends[i] = scalars[i] == "\n" || scalars[i] == "\r" ? i : ends[i + 1]
        }
        nextContent = content
        lineEnds = ends
        var hashRuns = Array(repeating: 0, count: scalars.count + 1)
        var raw = Array(repeating: -1, count: scalars.count + 1)
        var triple = raw
        for i in scalars.indices.reversed() {
            hashRuns[i] = scalars[i] == "#" ? hashRuns[i + 1] + 1 : 0
            raw[i] = raw[i + 1]
            triple[i] = triple[i + 1]
            if scalars[i] == "\"" {
                raw[i] = max(raw[i], hashRuns[i + 1])
                if i + 2 < scalars.count, scalars[i + 1] == "\"", scalars[i + 2] == "\"" {
                    triple[i] = max(triple[i], hashRuns[i + 3])
                }
            }
        }
        rawClosingHashes = raw
        tripleClosingHashes = triple
        output.reserveCapacity(code.utf8.count)
    }

    var id: String { language.id }
    var count: Int { source.count }
    func text(_ start: Int, _ end: Int) -> String { String(String.UnicodeScalarView(source[start..<end])) }
    func at(_ position: Int) -> Unicode.Scalar? { position < count ? source[position] : nil }
    func matches(_ value: String, at position: Int) -> Bool {
        let scalars = value.unicodeScalars
        guard position + scalars.count <= count else { return false }
        return zip(source[position...], scalars).allSatisfy { $0 == $1 }
    }
    func isWord(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
            || scalar == "_" || ((id == "javascript" || id == "typescript" || id == "php") && scalar == "$")
    }
    func wordEnd(_ start: Int) -> Int {
        var end = start
        while end < count,
            isWord(source[end])
                || (["css", "yaml", "toml", "ini", "html", "xml"].contains(id)
                    && "-:.".unicodeScalars.contains(source[end]) && source[end] != ":")
        { end += 1 }
        return end
    }
    mutating func emit(to end: Int, kind: String? = nil) {
        let escaped = HTML.escape(text(index, end))
        if let kind { output += "<span class=\"hl-\(kind)\">\(escaped)</span>" } else { output += escaped }
        for i in index..<end where source[i] == "\n" || source[i] == "\r" { lineStart = i + 1 }
        index = end
    }

    mutating func render() -> String {
        while index < count {
            let c = source[index]
            if id == "diff" {
                renderDiffLine()
                continue
            }
            if id == "html" || id == "xml" {
                renderMarkup()
                continue
            }
            if c == "\n" || c == "\r" || CharacterSet.whitespaces.contains(c) {
                emit(to: index + 1)
                continue
            }
            if specialLine() || comment() || meta() || string() || variable() { continue }
            if id == "css", c == "{" { cssDepth += 1 }
            if id == "css", c == "}" { cssDepth = max(0, cssDepth - 1) }
            if id == "css", c == "#" {
                var end = index + 1
                while end < count, "0123456789abcdefABCDEF".unicodeScalars.contains(source[end]) { end += 1 }
                if end > index + 1 {
                    emit(to: end, kind: "number")
                    continue
                }
            }
            if id == "css", c == "@" || matches("!important", at: index) {
                emit(to: wordEnd(index + 1), kind: "keyword")
                continue
            }
            if CharacterSet.decimalDigits.contains(c)
                || (c == "." && at(index + 1).map(CharacterSet.decimalDigits.contains) == true)
            {
                number()
                continue
            }
            if isWord(c) || (id == "css" && c == "-") {
                identifier()
                continue
            }
            if id == "yaml", c == "~" {
                emit(to: index + 1, kind: "literal")
                continue
            }
            emit(to: index + 1)
        }
        return output
    }

    mutating func specialLine() -> Bool {
        let first = nextContent[lineStart]
        let atStart = index == first
        let end = lineEnds[index]
        if index == 0, matches("#!", at: index), !(id == "rust" && matches("#![", at: index)) {
            emit(to: end, kind: "meta")
            return true
        }
        if atStart, language.preprocessor, source[index] == "#" {
            emit(to: end, kind: "meta")
            return true
        }
        if atStart, id == "yaml", matches("---", at: index) || matches("...", at: index) {
            let after = index + 3
            if after == end || at(after).map(CharacterSet.whitespaces.contains) == true {
                emit(to: after, kind: "meta")
                return true
            }
        }
        if atStart, ["ini", "toml"].contains(id), source[index] == "[" {
            var stop = index + 1
            while stop < end, source[stop] != "]" { stop += 1 }
            if stop < end {
                stop += 1
                if at(stop) == "]" { stop += 1 }
            }
            emit(to: stop, kind: "section")
            return true
        }
        if atStart, id == "makefile", !source[lineStart..<index].contains("\t") {
            var stop = index
            while stop < end, source[stop] != ":", source[stop] != "=", source[stop] != "#" { stop += 1 }
            if stop > index, stop < end, source[stop] == ":" {
                emit(to: stop, kind: "section")
                return true
            }
        }
        return false
    }

    mutating func comment() -> Bool {
        for delimiter in language.blockComments where matches(delimiter.open, at: index) {
            let opening = delimiter.open.unicodeScalars.count
            let closing = delimiter.close.unicodeScalars.count
            var end = index + opening
            var depth = 1
            while end < count {
                if matches(delimiter.close, at: end) {
                    depth -= 1
                    end += closing
                    if depth == 0 { break }
                } else if language.nestedComments, matches(delimiter.open, at: end) {
                    depth += 1
                    end += opening
                } else {
                    end += 1
                }
            }
            emit(to: end, kind: "comment")
            return true
        }
        for delimiter in language.lineComments where matches(delimiter, at: index) {
            if id == "shell", delimiter == "#", index > 0,
                !CharacterSet.whitespacesAndNewlines.contains(source[index - 1])
            {
                continue
            }
            emit(to: lineEnds[index], kind: "comment")
            return true
        }
        return false
    }

    mutating func string() -> Bool {
        var start = index
        var hashes = 0
        var verbatim = false
        if id == "python" {
            var end = start
            while end < min(start + 3, count), "rRbBuUfF".unicodeScalars.contains(source[end]) { end += 1 }
            if at(end) == "\"" || at(end) == "'" { start = end }
        }
        if id == "rust", at(start) == "r" { start += 1 }
        if id == "swift" || (id == "rust" && start > index) {
            while at(start) == "#" {
                hashes += 1
                start += 1
            }
            if start != index, at(start) != "\"" {
                if hashes > 0 {
                    emit(to: start)
                    return true
                }
                return false
            }
        }
        if id == "csharp", matches("@\"", at: start) {
            start += 1
            verbatim = true
        }
        guard let quote = at(start),
            quote == "\"" || quote == "'" || (quote == "`" && ["javascript", "typescript", "go", "shell"].contains(id))
        else { return false }
        // Rust lifetimes are identifiers, not unterminated character literals.
        if id == "rust", quote == "'", let next = at(start + 1), isWord(next), at(start + 2) != "'" { return false }
        let triple =
            ["python", "swift", "toml"].contains(id) && matches(String(repeating: String(quote), count: 3), at: start)
        let width = triple ? 3 : 1
        let multiline = triple || quote == "`" || hashes > 0 || verbatim || (id == "rust" && start > index)
        let delimiter = String(repeating: String(quote), count: width) + String(repeating: "#", count: hashes)
        let possibleRawClose = (triple ? tripleClosingHashes : rawClosingHashes)[start + width] >= hashes
        let canSearch = multiline && !exhaustedStrings.contains(delimiter) && (hashes == 0 || possibleRawClose)
        let searchLimit = canSearch ? count : lineEnds[index]
        var end = start + width
        var closed = false
        while end < searchLimit {
            if !multiline, source[end] == "\n" || source[end] == "\r" { break }
            if source[end] == quote {
                if verbatim, at(end + 1) == quote {
                    end += 2
                    continue
                }
                var closing = end
                while closing < min(end + width, count), source[closing] == quote { closing += 1 }
                if closing - end == width {
                    var hashEnd = closing
                    while hashEnd < min(closing + hashes, count), source[hashEnd] == "#" { hashEnd += 1 }
                    if hashEnd - closing == hashes {
                        end = hashEnd
                        closed = true
                        break
                    }
                    end = hashEnd
                    continue
                }
            }
            if source[end] == "\\", id == "swift", hashes > 0 {
                var escapeEnd = end + 1
                while escapeEnd < min(end + 1 + hashes, count), source[escapeEnd] == "#" { escapeEnd += 1 }
                if escapeEnd == end + 1 + hashes {
                    end = min(escapeEnd + 1, count)
                    continue
                }
            }
            if source[end] == "\\", !verbatim, hashes == 0,
                !(id == "go" && quote == "`")
                    && !(id == "rust" && start > index)
            {
                if end + 1 < count, multiline || (source[end + 1] != "\n" && source[end + 1] != "\r") {
                    end += 2
                    continue
                }
            }
            end += 1
        }
        if !closed, multiline {
            if searchLimit == count { exhaustedStrings.insert(delimiter) }
            end = lineEnds[index]
        }
        var kind = "string"
        let next = nextContent[end]
        if id == "json", at(next) == ":" { kind = "attr" }
        if isConfigurationKey(at: next) { kind = "attr" }
        emit(to: end, kind: kind)
        return true
    }

    mutating func variable() -> Bool {
        let c = source[index]
        if id == "yaml", c == "&" || c == "*" {
            let end = wordEnd(index + 1)
            if end > index + 1 {
                emit(to: end, kind: "variable")
                return true
            }
        }
        guard ["shell", "php", "makefile", "dockerfile"].contains(id), c == "$" else { return false }
        var end = index + 1
        if at(end) == "{" || (id == "makefile" && at(end) == "(") {
            let closing: Unicode.Scalar = at(end) == "{" ? "}" : ")"
            end += 1
            while end < lineEnds[index], source[end] != closing { end += 1 }
            if at(end) == closing { end += 1 }
        } else {
            end = wordEnd(end)
            if end == index + 1, let next = at(end), "@*#?$!_-".unicodeScalars.contains(next) { end += 1 }
        }
        guard end > index + 1 else { return false }
        emit(to: end, kind: "variable")
        return true
    }

    mutating func meta() -> Bool {
        if language.decorators, source[index] == "@" {
            let end = wordEnd(index + 1)
            if end > index + 1 {
                emit(to: end, kind: "meta")
                return true
            }
        }
        if id == "rust", matches("#[", at: index) || matches("#![", at: index) {
            var end = index + 2
            var depth = 1
            if at(end) == "[" { end += 1 }
            while end < count {
                if source[end] == "[" { depth += 1 }
                if source[end] == "]" { depth -= 1 }
                end += 1
                if depth == 0 { break }
            }
            emit(to: end, kind: "meta")
            return true
        }
        return false
    }

    mutating func number() {
        var end = index
        if matches("0x", at: index) || matches("0X", at: index) || matches("0b", at: index) || matches("0B", at: index)
            || matches("0o", at: index) || matches("0O", at: index)
        {
            end += 2
            while end < count, "0123456789abcdefABCDEF_".unicodeScalars.contains(source[end]) { end += 1 }
        } else {
            while end < count, "0123456789_".unicodeScalars.contains(source[end]) { end += 1 }
            if at(end) == ".", at(end + 1).map(CharacterSet.decimalDigits.contains) == true {
                end += 1
                while end < count, "0123456789_".unicodeScalars.contains(source[end]) { end += 1 }
            }
            if at(end) == "e" || at(end) == "E" {
                end += 1
                if at(end) == "+" || at(end) == "-" { end += 1 }
                while end < count, "0123456789_".unicodeScalars.contains(source[end]) { end += 1 }
            }
        }
        if end < count, CharacterSet.letters.contains(source[end]) {
            while end < count, CharacterSet.alphanumerics.contains(source[end]) { end += 1 }
        }
        if id == "css", at(end) == "%" { end += 1 }
        emit(to: max(end, index + 1), kind: "number")
    }

    func isConfigurationKey(at next: Int) -> Bool {
        guard next <= lineEnds[index] else { return false }
        let first = nextContent[lineStart]
        if id == "yaml", at(next) == ":" {
            return index == first
                || (at(first) == "-" && at(first + 1).map(CharacterSet.whitespaces.contains) == true
                    && index == nextContent[first + 1])
        }
        return (id == "ini" || id == "toml") && at(next) == "=" && index == first
    }

    mutating func identifier() {
        let end = max(wordEnd(index + (source[index] == "-" ? 1 : 0)), index + 1)
        let word = text(index, end)
        let folded = ["sql", "dockerfile", "yaml"].contains(id) ? word.lowercased() : word
        let next = at(nextContent[end])
        var kind: String?
        if id == "css", cssDepth > 0, next == ":" {
            kind = "attr"
        } else if isConfigurationKey(at: nextContent[end]) || (id == "json" && next == ":") {
            kind = "attr"
        } else if language.keywords.contains(folded), id != "dockerfile" || index == nextContent[lineStart] {
            kind = "keyword"
        } else if language.literals.contains(folded) {
            kind = "literal"
        } else if language.types.contains(folded) || (language.capitalizedTypes && source[index].properties.isUppercase)
        {
            kind = "type"
        } else if language.builtins.contains(folded) {
            kind = "builtin"
        } else if next == "(" {
            kind = "function"
        }
        emit(to: end, kind: kind)
    }

    mutating func renderDiffLine() {
        let end = lineEnds[index]
        if end == index {
            emit(to: index + 1)
            return
        }
        let kind: String?
        if ["diff ", "index ", "+++", "---"].contains(where: { matches($0, at: index) }) {
            kind = "meta"
        } else if matches("@@", at: index) {
            kind = "section"
        } else if source[index] == "+" {
            kind = "addition"
        } else if source[index] == "-" {
            kind = "deletion"
        } else {
            kind = nil
        }
        emit(to: end, kind: kind)
    }

    mutating func renderMarkup() {
        if !inTag, let rawTag {
            var end = index
            let closing = "</" + rawTag
            while end < count {
                if source[end] == "<", end + closing.count <= count,
                    text(end, end + closing.count).lowercased() == closing,
                    at(end + closing.count) == ">"
                        || at(end + closing.count).map(CharacterSet.whitespacesAndNewlines.contains) == true
                {
                    break
                }
                end += 1
            }
            self.rawTag = nil
            if end > index {
                emit(to: end)
                return
            }
        }
        if matches("<!--", at: index) || matches("<!", at: index) || matches("<?", at: index) {
            let comment = matches("<!--", at: index)
            let close = comment ? "-->" : (matches("<?", at: index) ? "?>" : ">")
            var end = index + (comment ? 4 : 2)
            while end < count, !matches(close, at: end) { end += 1 }
            if end < count { end += close.count }
            emit(to: end, kind: comment ? "comment" : "meta")
            return
        }
        let c = source[index]
        if c == "<" {
            inTag = true
            wantsTagName = true
            closingTag = at(index + 1) == "/"
            wantsAttributeValue = false
            emit(to: index + 1)
            return
        }
        if c == ">" {
            if index > 0, source[index - 1] == "/" { rawTag = nil }
            inTag = false
            emit(to: index + 1)
            return
        }
        if inTag, c == "=" {
            wantsAttributeValue = true
            emit(to: index + 1)
            return
        }
        if inTag, c == "\"" || c == "'", string() {
            wantsAttributeValue = false
            return
        }
        if c == "&" {
            var end = index + 1
            while end < count, isWord(source[end]) || source[end] == "#" { end += 1 }
            if at(end) == ";" {
                emit(to: end + 1, kind: "literal")
                return
            }
            emit(to: end)
            return
        }
        if inTag, wantsAttributeValue, !CharacterSet.whitespacesAndNewlines.contains(c) {
            var end = index + 1
            while end < count, !CharacterSet.whitespacesAndNewlines.contains(source[end]), source[end] != ">" {
                end += 1
            }
            emit(to: end)
            wantsAttributeValue = false
            return
        }
        if inTag, isWord(c) {
            var end = wordEnd(index)
            while end < count, source[end] == ":" { end = max(end + 1, wordEnd(end + 1)) }
            if wantsTagName, !closingTag {
                let name = text(index, end).lowercased()
                if name == "script" || name == "style" { rawTag = name }
            }
            emit(to: end, kind: wantsTagName ? "tag" : "attr")
            wantsTagName = false
            return
        }
        emit(to: index + 1)
    }
}
