import Foundation

enum OrgInline {
    enum Cookies { case none, all, edges }

    static let timestampPattern =
        #"(?:<[0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^<>\[\]\n]*)?>|\[[0-9]{4}-[0-9]{2}-[0-9]{2}(?: [^<>\[\]\n]*)?\])"#

    static func timestamp(_ source: String) -> String {
        let inactive = source.hasPrefix("[") ? " org-timestamp-inactive" : ""
        return "<time class=\"org-timestamp\(inactive)\">\(HTML.escape(String(source.dropFirst().dropLast())))</time>"
    }

    static func planning(_ text: String) -> String? {
        let entry = "(SCHEDULED|DEADLINE|CLOSED):[ \t]*(" + timestampPattern + "(?:--" + timestampPattern + ")?)"
        guard orgCaptures("^(?:" + entry + "[ \t]*)+$", text) != nil,
            let regex = orgExpression(entry)
        else { return nil }
        let items = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            match -> String? in
            guard let labelRange = Range(match.range(at: 1), in: text),
                let timeRange = Range(match.range(at: 2), in: text)
            else { return nil }
            let label = String(text[labelRange]).uppercased()
            let times = text[timeRange].components(separatedBy: "--").map(timestamp).joined(separator: "–")
            return
                "<span class=\"org-planning-item org-\(label.lowercased())\"><span class=\"org-planning-label\">\(label)</span> \(times)</span>"
        }
        return "<p class=\"org-planning\">" + items.joined(separator: " ") + "</p>\n"
    }

    private static let plainLinkTypes: Set<String> = ["http", "https", "ftp", "mailto", "file", "doi", "news"]

    /// The end of the address that starts at `start`: a link type and a colon at the start of a word, then
    /// everything up to white space, an unmatched square bracket, an angle bracket or an unopened parenthesis, without the punctuation that ends
    /// it. A slash may end it.
    private static func plainLinkEnd(_ characters: [Character], brackets: [Int: Int], from start: Int) -> Int? {
        if start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber { return nil }
        var colon = start
        while colon < characters.count, colon - start < 7, characters[colon].isASCII, characters[colon].isLetter {
            colon += 1
        }
        guard colon > start, colon < characters.count, characters[colon] == ":",
            plainLinkTypes.contains(String(characters[start..<colon]).lowercased())
        else { return nil }
        var end = colon + 1
        var open = 0
        while end < characters.count {
            let character = characters[end]
            if character == "[", let close = brackets[end] {
                end = close + 1
                continue
            }
            if character.isWhitespace || "[]<>".contains(character) { break }
            if character == "(" { open += 1 }
            if character == ")" {
                if open == 0 { break }
                open -= 1
            }
            end += 1
        }
        while end > colon + 1, characters[end - 1].isPunctuation, !"/)]".contains(characters[end - 1]) { end -= 1 }
        return end > colon + 1 ? end : nil
    }

    static func render(_ text: String, context: OrgContext = OrgContext(), depth: Int = 0, cookies: Cookies = .none)
        -> String
    {
        guard depth < 32, StackSpace.hasRoom else {
            StackSpace.noteLimitReached()
            return HTML.escape(text)
        }
        // Index tokens once, so a run of unmatched openers never rescans the remaining suffix.
        let pattern = timestampPattern + #"|\[(?:[0-9]*/[0-9]*|[0-9]*%)\]"#
        let nsText = text as NSString
        let matches =
            orgExpression(pattern)?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        var tokens: [Int: (end: Int, source: String)] = [:]
        var utf16 = 0
        var offsets: [Int: Int] = [:]
        var utf16Offsets: [Int] = []
        for (offset, character) in text.enumerated() {
            offsets[utf16] = offset
            utf16Offsets.append(utf16)
            utf16 += String(character).utf16.count
        }
        offsets[utf16] = text.count
        for match in matches {
            if let start = offsets[match.range.location], let end = offsets[NSMaxRange(match.range)] {
                tokens[start] = (end, nsText.substring(with: match.range))
            }
        }
        let characters = Array(text)
        var brackets: [Int: Int] = [:]
        var linkBrackets: [Int: Int] = [:]
        var lastSpace = -1
        var stack: [Int] = []
        // The closing brace or parenthesis of each opener a subscript or superscript may start with. Paired once,
        // so a run of unclosed openers never rescans the rest of the text.
        let scripts = context.reading.scripts
        var groups: [Int: Int] = [:]
        // Each open group with the depth of the groups closed inside it. Org's expression follows a group two
        // levels down and no further; a deeper one is no script.
        var braces: [(start: Int, inner: Int)] = []
        var parentheses: [(start: Int, inner: Int)] = []
        func close(_ open: inout [(start: Int, inner: Int)], at position: Int) {
            guard let group = open.popLast() else { return }
            if group.inner <= 2 { groups[group.start] = position }
            if let last = open.indices.last { open[last].inner = max(open[last].inner, group.inner + 1) }
        }
        for (position, character) in characters.enumerated() {
            if character.isWhitespace { lastSpace = position }
            if character == "[" {
                stack.append(position)
            } else if character == "]", let start = stack.popLast() {
                brackets[start] = position
                if start > lastSpace { linkBrackets[start] = position }
            } else if character == "\n" {
                stack.removeAll(keepingCapacity: true)
            }
            guard scripts != .off else { continue }
            switch character {
            case "{": braces.append((position, 0))
            case "}": close(&braces, at: position)
            case "(": parentheses.append((position, 0))
            case ")": close(&parentheses, at: position)
            default: break
            }
        }
        /// The end of the subscript or superscript whose `_` or `^` stands at `marker`, and its HTML. As in Org,
        /// the script is `{…}`, `(…)`, `*`, or a signed run of letters, digits, commas, dots and backslashes that
        /// ends in a letter or digit; the character before the marker is not white space.
        func script(at marker: Int) -> (end: Int, html: String)? {
            guard scripts != .off, marker > 0, !characters[marker - 1].isWhitespace, marker + 1 < characters.count
            else { return nil }
            let start = marker + 1
            let tag = characters[marker] == "_" ? "sub" : "sup"
            func nested(_ range: Range<Int>) -> String {
                render(String(characters[range]), context: context, depth: depth + 1, cookies: cookies)
            }
            if characters[start] == "{" {
                // Emacs prints the word "nil" for an empty group; the characters stay as written instead.
                guard let end = groups[start], end > start + 1 else { return nil }
                return (end + 1, "<\(tag)>\(nested((start + 1)..<end))</\(tag)>")
            }
            guard scripts == .all else { return nil }
            if characters[start] == "(" {
                guard let end = groups[start] else { return nil }
                return (end + 1, "<\(tag)>(\(nested((start + 1)..<end)))</\(tag)>")
            }
            if characters[start] == "*" { return (start + 1, "<\(tag)>*</\(tag)>") }
            var end = start + (characters[start] == "+" || characters[start] == "-" ? 1 : 0)
            var last: Int?
            while end < characters.count {
                let character = characters[end]
                if character.isLetter || character.isNumber {
                    last = end
                } else if !",.\\".contains(character) {
                    break
                }
                end += 1
            }
            guard let last else { return nil }
            return (last + 1, "<\(tag)>\(HTML.escape(String(characters[start...last])))</\(tag)>")
        }
        // A formula is looked for only where the scan arrives, so one that would open inside code, which the scan
        // steps over, cannot hide what follows the code. Each position is tried once.
        var formulaEnds: [Int: Int?] = [:]
        func formulaEnd(_ position: Int) -> Int? {
            guard characters[position] == "$" || characters[position] == "\\" else { return nil }
            if let known = formulaEnds[position] { return known }
            let start = utf16Offsets[position]
            let match = orgExpression(OrgMath.inlinePattern)?.firstMatch(
                in: text, options: [.anchored, .withTransparentBounds],
                range: NSRange(location: start, length: nsText.length - start))
            let end = match.flatMap { offsets[NSMaxRange($0.range)] }
            formulaEnds[position] = .some(end)
            return end
        }
        let tags: [Character: String] = ["*": "strong", "/": "em", "_": "u", "=": "code", "~": "code", "+": "del"]
        var output = ""
        var index = 0
        var linkSearchExhausted = false
        // The first opener of each kind known to have no closing delimiter after it. The search for one kind looks
        // ahead of the scan, so a failure there says nothing about openers before it.
        var exhaustedEmphasis: [Character: Int] = [:]
        func opensEmphasis(_ position: Int) -> Bool {
            tags[characters[position]] != nil && position < exhaustedEmphasis[characters[position]] ?? Int.max
                && position + 1 < characters.count && !characters[position + 1].isWhitespace
                && (position == 0 || characters[position - 1].isWhitespace
                    || "-({'\"".contains(characters[position - 1]))
        }
        /// The closing delimiter for the one at `opener`. Code is literal; in other emphasis, a delimiter inside a
        /// formula or inside code belongs to that formula or code, as the main scan will read them.
        func emphasisEnd(_ opener: Int) -> Int? {
            let character = characters[opener]
            let literal = tags[character] == "code"
            var position = opener + 1
            while position < characters.count {
                if !literal, let end = formulaEnd(position) {
                    position = end
                    continue
                }
                if position > opener + 1, characters[position] == character,
                    !characters[position - 1].isWhitespace,
                    position + 1 == characters.count || characters[position + 1].isWhitespace
                        || "-.,;:!?'\")}[\\".contains(characters[position + 1])
                {
                    return position
                }
                if !literal, tags[characters[position]] == "code", opensEmphasis(position),
                    let end = emphasisEnd(position)
                {
                    position = end + 1
                    continue
                }
                position += 1
            }
            // Once no closing delimiter remains, later openers of this kind cannot succeed either.
            exhaustedEmphasis[character] = min(opener, exhaustedEmphasis[character] ?? Int.max)
            return nil
        }
        while index < characters.count {
            if let end = formulaEnd(index) {
                output += OrgMath.inline(String(characters[index..<end]), context: context)
                index = end
                continue
            }
            var token = tokens[index]
            if index + 3 < characters.count, characters[index] == "[", characters[index + 1] == "f",
                characters[index + 2] == "n", characters[index + 3] == ":", let end = brackets[index]
            {
                token = (end + 1, String(characters[index...end]))
            }
            if let token {
                let source = token.source
                var html: String?
                if source.hasPrefix("[fn:") {
                    let inner = String(source.dropFirst(4).dropLast())
                    var label = inner
                    if let colon = inner.firstIndex(of: ":") {
                        label = String(inner[..<colon])
                        if label.isEmpty {
                            context.anonymous += 1
                            label = "\u{0}anonymous-\(context.anonymous)"
                        }
                        let definition = String(inner[inner.index(after: colon)...]).trimmingCharacters(
                            in: .whitespaces)
                        if context.discovering || label.hasPrefix("\u{0}") || context.definitions[label] == nil {
                            context.definitions[label] = definition
                        }
                        if context.discovering {
                            _ = render(definition, context: context, depth: depth + 1)
                        }
                    }
                    html = context.reference(label, depth: depth)
                } else if source.hasPrefix("<")
                    || source.dropFirst().prefix(4).allSatisfy(\.isNumber) && source.dropFirst(5).hasPrefix("-")
                {
                    html = timestamp(source)
                } else if cookies == .all || cookies == .edges && (index == 0 || token.end == characters.count) {
                    html = "<span class=\"org-cookie\">\(HTML.escape(source))</span>"
                }
                output += html ?? HTML.escape(source)
                index = token.end
                if html?.hasPrefix("<time ") == true, index + 2 < characters.count,
                    characters[index] == "-", characters[index + 1] == "-",
                    let next = tokens[index + 2], !next.source.hasPrefix("[fn:"),
                    orgCaptures("^" + timestampPattern + "$", next.source) != nil
                {
                    output += "–"
                    index += 2
                }
                continue
            }
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\\",
                index + 2 == characters.count || characters[index + 2] == "\n"
            {
                output += "<br>"
                index += 2
                continue
            }
            var linkEnd: Int?
            if !linkSearchExhausted, index + 1 < characters.count,
                characters[index] == "[", characters[index + 1] == "["
            {
                linkEnd = ((index + 2)..<max(index + 2, characters.count - 1)).first(where: {
                    characters[$0] == "]" && characters[$0 + 1] == "]"
                })
                // A failed search covers the entire suffix; later openers cannot have a closing pair.
                linkSearchExhausted = linkEnd == nil
            }
            if let end = linkEnd {
                let inner = String(characters[(index + 2)..<end])
                let parts = inner.components(separatedBy: "][")
                let destination = parts[0].hasPrefix("file:") ? String(parts[0].dropFirst(5)) : parts[0]
                // Only a description is markup. A link without one shows its address as written.
                let label = parts.count > 1 ? parts.dropFirst().joined(separator: "][") : destination
                let path = destination.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                let suffix = (path as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "heic"].contains(suffix) {
                    output += "<img src=\"\(HTML.escape(destination))\" alt=\"\(HTML.escape(label))\">"
                } else {
                    let labelHTML =
                        parts.count > 1 ? render(label, context: context, depth: depth + 1) : HTML.escape(label)
                    output += "<a href=\"\(HTML.escape(destination))\">\(labelHTML)</a>"
                }
                index = end + 2
                continue
            }
            let character = characters[index]
            // An address in the text is one piece, whatever the document says about scripts: none of its
            // characters is markup.
            if character.isLetter, let end = plainLinkEnd(characters, brackets: linkBrackets, from: index) {
                output += HTML.escape(String(characters[index..<end]))
                index = end
                continue
            }
            if let tag = tags[character], opensEmphasis(index), let end = emphasisEnd(index) {
                let inner = String(characters[(index + 1)..<end])
                output +=
                    "<\(tag)>\(tag == "code" ? HTML.escape(inner) : render(inner, context: context, depth: depth + 1, cookies: cookies))</\(tag)>"
                index = end + 1
            } else if character == "_" || character == "^", let script = script(at: index) {
                output += script.html
                index = script.end
            } else {
                output += HTML.escape(String(character))
                index += 1
            }
        }
        return output
    }
}
