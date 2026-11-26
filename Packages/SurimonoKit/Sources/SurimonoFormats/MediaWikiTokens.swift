import Foundation

extension WikiReader {
    private static let tags = WikiPattern(
        #"<!--|-->|</?[A-Za-z][A-Za-z0-9:-]*(?:\s++(?:[^<>"']|"[^"<>]*"|'[^'<>]*')*+)?/?>"#)
    private static let braces = WikiPattern(#"\{+|\}+|\[\[|\]\]"#)
    static let attributePattern = WikiPattern(#"(?<![\w:-])([\w:-]++)\s*+=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>/=]+))"#)
    static let allowed: Set<String> = [
        "br", "hr", "blockquote", "code", "tt", "kbd", "small", "big", "sub", "sup", "s", "del", "u", "ins",
        "span", "div", "center", "abbr", "cite", "q", "dl", "dt", "dd", "ol", "ul", "li", "table", "thead",
        "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
    ]
    // These are ordinary HTML elements outside wikitext's allow-list. Site extensions instead get a printed notice.
    static let literalTags = Set(
        """
        a address area article aside audio b base bdi bdo body button canvas data datalist details dfn dialog em
        embed fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hgroup html i iframe img input
        label legend link main map mark menu meta meter nav noscript object optgroup option output p param picture
        portal progress rp rt ruby samp script search section select slot strong style summary svg template textarea
        time title track var video wbr acronym applet basefont bgsound blink dir font frame frameset keygen marquee
        nobr noembed noframes plaintext rb rtc strike xmp
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let parsedTags: Set<String> = [
        "math", "chem", "nowiki", "pre", "syntaxhighlight", "source", "poem", "ref", "references", "gallery",
    ]

    static func attributes(_ source: String) -> [String: String] {
        var attrs: [String: String] = [:]
        _ = attributePattern.replace(source) { m in
            attrs[m[1].lowercased()] = m.dropFirst(2).first { !$0.isEmpty } ?? ""
            return ""
        }
        return attrs
    }

    static func safeAttributes(_ attrs: [String: String], cell: Bool = false) -> String {
        let allowed =
            cell
            ? ["class", "colspan", "rowspan", "style"]
            : ["class", "id", "style", "lang", "title", "colspan", "rowspan", "align", "start", "value", "scope"]
        return allowed.compactMap { name in
            guard var value = attrs[name] else { return nil }
            if name == "style", cell {
                value = value.components(separatedBy: ";").map(\.wikiTrim).filter {
                    $0.range(
                        of: #"(?i)^text-align\s*:\s*(left|right|center|justify|start|end)$"#,
                        options: .regularExpression) != nil
                }.joined(separator: ";")
                if value.isEmpty { return nil }
            }
            return " \(name)=\"\(HTML.escape(value))\""
        }.joined()
    }

    private struct Token {
        var range: NSRange
        var kind: String
        var closing: Bool
        var mate: Int?
    }

    func tokenize(_ input: String) -> String {
        let source = input as NSString
        var tokens: [Token] = []
        var opens: [String: [Int]] = [:]
        Self.tags.forEachMatch(in: input) { match in
            let raw = source.substring(with: match.range)
            let closing = raw.hasPrefix("</") || raw == "-->"
            let tag =
                raw == "<!--" || raw == "-->"
                ? "!--"
                : String(raw.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" })
                    .lowercased()
            var token = Token(range: match.range, kind: tag, closing: closing)
            if closing {
                if let index = opens[tag]?.popLast() { tokens[index].mate = tokens.count }
            } else if raw.hasSuffix("/>") || ["br", "hr", "col"].contains(tag) {
                token.mate = tokens.count
            } else {
                opens[tag, default: []].append(tokens.count)
            }
            tokens.append(token)
        }

        if PreviewConversion.expired { return "" }

        // Verbatim content ends at the next closing tag, even if its literal text looks like another opener.
        var nextClose: [String: Int] = [:]
        for i in tokens.indices.reversed() {
            if i.isMultiple(of: 128), PreviewConversion.expired { return "" }
            guard ["!--", "nowiki", "pre", "source", "syntaxhighlight", "math", "chem"].contains(tokens[i].kind)
            else { continue }
            let token = tokens[i]
            if token.closing {
                nextClose[token.kind] = i
            } else if token.mate != i {
                tokens[i].mate = nextClose[token.kind]
            }
        }

        func region(_ start: Int, _ end: Int, _ bounds: NSRange, _ nesting: Int) -> String {
            var text = ""
            var cursor = bounds.location
            var i = start
            while i < end {
                if PreviewConversion.expired { return "" }
                let t = tokens[i]
                let raw = source.substring(with: t.range)
                text += source.substring(with: NSRange(location: cursor, length: t.range.location - cursor))
                cursor = NSMaxRange(t.range)
                let name = t.kind
                if Self.allowed.contains(name) {
                    let attrs = Self.attributes(raw)
                    var html = t.closing ? "</\(name)>" : "<\(name)\(Self.safeAttributes(attrs))>"
                    if raw.hasSuffix("/>"), !["br", "hr", "col"].contains(name) { html += "</\(name)>" }
                    text += atom("html", html)
                } else if !t.closing, let close = t.mate, close < end, !Self.literalTags.contains(name) {
                    let paired = close > i
                    let interior = NSRange(location: cursor, length: paired ? tokens[close].range.location - cursor : 0)
                    if name != "!--", !Self.parsedTags.contains(name) {
                        text += atom("unsupported", name)
                    } else if name != "!--" {
                        let content =
                            ["ref", "poem", "gallery"].contains(name) && nesting < 24
                            ? region(i + 1, close, interior, nesting + 1) : source.substring(with: interior)
                        text += atom(name, content, Self.attributes(raw))
                    }
                    cursor = NSMaxRange(tokens[close].range)
                    i = close
                } else {
                    text += atom("literal", raw)
                }
                i += 1
            }
            text += source.substring(with: NSRange(location: cursor, length: NSMaxRange(bounds) - cursor))
            return groupBraces(text)
        }
        return region(0, tokens.count, NSRange(location: 0, length: source.length), 0)
    }

    // Pair delimiters before descending. An unmatched opener costs one stack entry and never rescans its suffix.
    private func groupBraces(_ input: String) -> String {
        guard input.contains("{{") || input.contains("[[") else { return input }
        let source = input as NSString
        var tokens: [Token] = []
        var stack: [Int] = []
        Self.braces.forEachMatch(in: input) { m in
            let char = source.character(at: m.range.location)
            let closing = char == 125 || char == 93
            let link = char == 91 || char == 93
            var pos = m.range.location
            let end = NSMaxRange(m.range)
            while end - pos >= 2 {
                if tokens.count.isMultiple(of: 128), PreviewConversion.expired { return }
                let triple =
                    !link
                    && (closing
                        ? stack.last.map { tokens[$0].kind == "parameter" } == true && end - pos >= 3 : end - pos == 3)
                let size = triple ? 3 : 2
                let kind = link ? "link" : (triple ? "parameter" : "template")
                if !closing {
                    stack.append(tokens.count)
                } else if let top = stack.last, tokens[top].kind == kind {
                    stack.removeLast()
                    tokens[top].mate = tokens.count
                }
                tokens.append(Token(range: NSRange(location: pos, length: size), kind: kind, closing: closing))
                pos += size
            }
        }
        if PreviewConversion.expired { return "" }
        func region(_ start: Int, _ end: Int, _ begin: Int, _ finish: Int, _ nesting: Int) -> String {
            var output = ""
            var cursor = begin
            var i = start
            while i < end {
                if PreviewConversion.expired { return "" }
                let t = tokens[i]
                if let close = t.mate, close < end {
                    output += source.substring(with: NSRange(location: cursor, length: t.range.location - cursor))
                    let tail = tokens[close].range
                    if nesting < 32 {
                        let body = region(i + 1, close, NSMaxRange(t.range), tail.location, nesting + 1)
                        output += atom(t.kind, body)
                    } else {
                        output += source.substring(
                            with: NSRange(location: t.range.location, length: NSMaxRange(tail) - t.range.location))
                    }
                    cursor = NSMaxRange(tail)
                    i = close
                }
                i += 1
            }
            return output + source.substring(with: NSRange(location: cursor, length: finish - cursor))
        }
        return region(0, tokens.count, 0, source.length, 0)
    }
}
