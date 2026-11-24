import Foundation

/// The compositor receives finished HTML. Only prose text is eligible for vertical glyph treatment.
package enum VerticalText {
    package enum MarkupError: Error { case tooManySpans }

    package static func marked(_ html: String, latex: Bool = false) throws -> String {
        var writer = Writer()
        writer.output.reserveCapacity(html.utf8.count)
        var skipped: (name: String, depth: Int)?
        var plain = false
        var note = false
        var heading = false
        var numberDepth = 0
        var numberEnd: Int?
        var afterURL = 0
        var linkedURL: String?
        let tokens = HTMLScanner.tokens(html)
        for (index, token) in tokens.enumerated() {
            if index < afterURL { continue }
            switch token {
            case .opaque(let source): writer.markup(source)
            case .text(let text):
                if skipped != nil {
                    writer.markup(text)
                } else if let linkedURL, HTMLScanner.decodingEntities(text) == linkedURL {
                    try writer.url(text)
                } else {
                    try writer.text(text, plain: plain, note: note, headingNumber: heading) { direction in
                        // A section number and its title are separate runs even without intervening HTML text.
                        if numberDepth > 0 { return nil }
                        var i = index + direction
                        while tokens.indices.contains(i) {
                            if i == numberEnd { return nil }
                            switch tokens[i] {
                            case .text(let neighbor): return direction < 0 ? neighbor.last : neighbor.first
                            case .tag(let tag)
                            where !inlineElements.contains(tag.name) || tag.name == "ruby" || tag.name == "sup":
                                return nil
                            default: i += direction
                            }
                        }
                        return nil
                    }
                }
            case .tag(let tag):
                if let current = skipped {
                    writer.markup(tag.source)
                    if current.name == tag.name && !tag.isSelfClosing {
                        let depth = current.depth + (tag.isClosing ? -1 : 1)
                        skipped = depth == 0 ? nil : (current.name, depth)
                    }
                    continue
                }
                let classes = tag.attribute("class")?.split(whereSeparator: \.isWhitespace) ?? []
                if latex, tag.name == "a", classes.contains("latex-url"), !tag.isClosing, !tag.isSelfClosing,
                    let url = latexURL(in: tokens[(index + 1)...])
                {
                    writer.markup(tag.source)
                    try writer.url(url.label)
                    writer.markup(url.close)
                    afterURL = url.next
                    continue
                }
                if latex && ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag.name) { heading = !tag.isClosing }
                if tag.name == "sup" { note = !tag.isClosing && classes.contains("footnote-ref") }
                if tag.name == "a" {
                    let href = tag.attribute("href")
                    linkedURL = href.flatMap { value in
                        value.contains("://") || value.hasPrefix("mailto:")
                            ? value.removingPercentEncoding ?? value : nil
                    }
                }
                let plainPre = tag.name == "pre" && classes.contains("surimono-plain")
                if let edge = protectedEdge(tag, classes: classes, latex: latex), !plainPre, !tag.isClosing {
                    // Ruby annotations are transparent to the boundary on either side of their base.
                    if tag.name != "rt" && tag.name != "rp" { try writer.begin(edge) }
                    if !tag.isSelfClosing { skipped = (tag.name, 1) }
                } else if latex && tag.name == "span" && !tag.isSelfClosing {
                    if numberDepth > 0 {
                        numberDepth += tag.isClosing ? -1 : 1
                        if numberDepth == 0 {
                            try writer.begin(.start)
                            numberEnd = index
                        }
                    } else if classes.contains("secnum") && !tag.isClosing {
                        try writer.begin(.start)
                        numberDepth = 1
                    }
                } else if !inlineElements.contains(tag.name) {
                    let paragraph = !tag.isClosing && (tag.name == "p" || plainPre)
                    try writer.begin(paragraph ? .paragraph : .start)
                    if tag.name == "pre" { plain = plainPre }
                }
                if tag.name == "em", !tag.isClosing, !tag.isSelfClosing,
                    tag.attribute("data-vertical-latin") == nil, latinEmphasis(in: tokens[(index + 1)...])
                {
                    writer.markup(tag.source.dropLast() + " data-vertical-latin>")
                } else {
                    writer.markup(tag.source)
                }
            }
        }
        try writer.begin(.start)
        return writer.output
    }

    private static let inlineElements: Set<String> = [
        "a", "b", "bdi", "bdo", "cite", "del", "em", "i", "ins", "kbd", "mark", "q", "ruby", "rb", "s",
        "small", "span", "strong", "sub", "sup", "time", "u", "wbr",
    ]

    private static func protectedEdge(_ tag: HTMLScanner.Tag, classes: [Substring], latex: Bool) -> Edge? {
        if ["table", "pre", "figure", "head", "script", "style", "textarea"].contains(tag.name)
            || classes.contains(where: {
                ["footnotes", "math-block", "math-display", "mermaid-block", "graphviz-block", "plantuml-block"]
                    .contains($0)
            })
        {
            return .start
        }
        if ["code", "math", "svg"].contains(tag.name)
            || classes.contains(where: { ["math", "math-inline", "v-latin"].contains($0) })
        {
            return .western
        }
        if ["rt", "rp"].contains(tag.name) || (latex && classes.contains { $0 == "kenten" || $0 == "bousen" })
            || classes.contains(where: {
                ["tcy", "upright-digit", "aki", "v-half", "v-close", "v-before-open"].contains($0)
            })
        {
            return .other
        }
        return nil
    }

    // The reader emits a URL as breakable spans. Rejoin just that label before applying
    // vertical breakpoints, so a numeric path component stays sideways and the href stays intact.
    private static func latexURL(in tokens: ArraySlice<HTMLScanner.Token>) -> (label: String, close: String, next: Int)?
    {
        var label = ""
        for index in tokens.indices {
            switch tokens[index] {
            case .text(let source): label += source
            case .tag(let tag) where tag.name == "a" && tag.isClosing: return (label, tag.source, index + 1)
            case .tag(let tag) where tag.name == "span" || tag.name == "wbr": continue
            default: return nil
            }
        }
        return nil
    }

    private static func latinEmphasis(in following: ArraySlice<HTMLScanner.Token>) -> Bool {
        var hasLetter = false
        for token in following {
            switch token {
            case .text(let source):
                let text = HTMLScanner.decodingEntities(source)
                if text.contains(/[^\p{sc=Latin}\p{Common}\p{Inherited}]/) { return false }
                hasLetter = hasLetter || text.contains(/\p{sc=Latin}/)
            case .tag(let tag):
                // A nested emphasis decides its own treatment. Stopping here also bounds the lookahead
                // to a single pass even if the source nests thousands of opening tags.
                if tag.name == "em" { return tag.isClosing && hasLetter }
                if !["span", "strong", "b", "i", "a", "sup", "sub"].contains(tag.name) { return false }
            case .opaque:
                continue
            }
        }
        return false
    }

    private enum Edge {
        case start, paragraph, japanese, western, opening, closing, other
    }

    private struct Writer {
        var output = ""
        private var remaining = 250_000
        private var last = Edge.start
        // Closing punctuation needs the next visible character. Spaces and intervening inline tags must
        // stay in their original order even when that character belongs to another link or emphasis.
        private var closing: String?
        private var pending: [(text: String, space: Bool)] = []
        private var hasSpace = false

        mutating func markup(_ raw: String) {
            if closing == nil && !hasSpace { output += raw } else { pending.append((raw, false)) }
        }

        mutating func begin(_ next: Edge) throws {
            if let closing {
                output += !hasSpace && next == .closing ? try span("v-close", closing) : closing
                self.closing = nil
            }
            let gap = (last == .japanese && next == .western) || (last == .western && next == .japanese)
            if gap && !hasSpace { output += try span("aki", "") }
            for piece in pending {
                output += gap && piece.space ? try span("aki", piece.text) : piece.text
            }
            pending.removeAll(keepingCapacity: true)
            hasSpace = false
            last = next
        }

        private mutating func span(_ name: String, _ source: String) throws -> String {
            guard remaining > 0 else { throw MarkupError.tooManySpans }
            remaining -= 1
            return "<span class=\"\(name)\">\(source)</span>"
        }

        mutating func text(
            _ source: String, plain: Bool, note: Bool, headingNumber: Bool, neighbor: (Int) -> Character?
        ) throws {
            // Matching complete words, URLs, numbers and entities keeps their punctuation and digits together.
            let token =
                #/
                &(?:\x23[xX][a-fA-F0-9]+|\x23[0-9]+|[a-zA-Z][a-zA-Z0-9]*);
                | [\p{sc=Latin}0-9]+(?:[.,][0-9]+[\p{sc=Latin}0-9]*)* %? | \.[0-9]+ %?
                | [!?]+ | [\x20]+ | \R+ | [\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー０-９]+ | .
                /#
            // Searching for a scheme from every short word in a dotted identifier would repeatedly
            // scan the same suffix. Each :// has just one possible scheme immediately to its left.
            var hosts: [String.Index: String.Index] = [:]
            for delimiter in source.ranges(of: "://") {
                var start = delimiter.lowerBound
                while start > source.startIndex {
                    let previous = source.index(before: start)
                    let char = source[previous]
                    guard char.isASCII && (char.isLetter || char.isNumber || "+.-".contains(char)) else { break }
                    start = previous
                }
                if start < delimiter.lowerBound && source[start].isLetter { hosts[start] = delimiter.upperBound }
            }
            let address = #/(?:[\p{L}\p{N}\-]+\.)*[A-Za-z0-9%._~:/?#\[\]@!$&'()*+,;=\-]+/#
            var rest = source[...]
            while !rest.isEmpty {
                var host = hosts[rest.startIndex]
                if host == nil, let first = rest.first, "wWmM".contains(first) {
                    host = rest.prefixMatch(of: /(?i:www\.|mailto:)/)?.range.upperBound
                }
                if let host, let match = rest[host...].prefixMatch(of: address) {
                    try url(String(rest[..<match.range.upperBound]))
                    rest = rest[match.range.upperBound...]
                    continue
                }
                guard let match = rest.prefixMatch(of: token) else {
                    // Preserve any grapheme the running OS's regex engine cannot classify.
                    try begin(.other)
                    output.append(rest.removeFirst())
                    continue
                }
                let raw = match.output
                if plain && raw.first?.isNewline == true {
                    try begin(.paragraph)
                    output += raw
                } else if raw.first == " " || raw.first?.isNewline == true {
                    pending.append((String(raw), true))
                    hasSpace = true
                } else {
                    let digits = raw.utf8.count <= 2 && raw.utf8.allSatisfy { (48...57).contains($0) }
                    if digits {
                        let before =
                            raw.startIndex == source.startIndex
                            ? neighbor(-1) : source[source.index(before: raw.startIndex)]
                        let after =
                            raw.endIndex == source.endIndex ? neighbor(1) : source[raw.endIndex]
                        let touchesWord = [before, after].compactMap { $0 }.contains {
                            $0.isASCII && ($0.isLetter || $0.isNumber || "%.,".contains($0))
                        }
                        if note || !touchesWord {
                            try begin(.other)
                            output += try span(
                                note || headingNumber || raw.count == 2 ? "tcy" : "upright-digit", String(raw))
                        } else {
                            try western(String(raw))
                        }
                    } else {
                        try glyphs(raw)
                    }
                }
                rest = rest[match.range.upperBound...]
            }
        }

        mutating func url(_ source: String) throws {
            // Keep the source spelling of HTML entities. A break inside &amp; would change the URL on copy.
            var body = ""
            var start = source.startIndex
            let separator = #/&(?:[a-zA-Z][a-zA-Z0-9]*|\x23[0-9]+|\x23[xX][a-fA-F0-9]+);|[/.\-_?&=\x23]/#
            while let match = source[start...].firstMatch(of: separator) {
                let end = match.range.upperBound
                body += source[start..<end]
                let character = HTMLScanner.decodingEntities(String(match.output))
                if character.count == 1 && "/.-_?&=#".contains(character) {
                    guard remaining > 0 else { throw MarkupError.tooManySpans }
                    remaining -= 1
                    body += "<wbr>"
                }
                start = end
            }
            body += source[start...]
            try begin(.western)
            output += try span("v-latin v-url", body)
        }

        mutating func western(_ source: String) throws {
            try begin(.western)
            output += try span("v-latin", source)
        }

        private mutating func glyphs(_ raw: Substring) throws {
            guard let first = raw.first else { return }
            if "「『（〔［｛〈《【〖〘〚".contains(first) {
                let atParagraph = last == .paragraph
                let trim = !hasSpace && [.start, .paragraph, .opening, .closing].contains(last)
                try begin(.opening)
                // A break can fall after the collapsible half space. Keep the negative margin
                // on the glyph itself so it follows the bracket onto its new line.
                if !trim { output += try span("v-before-open", "") }
                output += try span(atParagraph ? "v-half v-initial" : "v-half", String(raw))
            } else if "」』）〕］｝〉》】〗〙〛、。，．".contains(first) {
                try begin(.closing)
                closing = String(raw)
            } else if raw.utf8.count == 2 && (first == "!" || first == "?") {
                try begin(.other)
                output += try span("tcy", String(raw))
            } else if first.isASCII && (first.isLetter || first.isNumber || (first == "." && raw.count > 1))
                || raw.prefix(1).wholeMatch(of: /\p{sc=Latin}/) != nil
            {
                try western(String(raw))
            } else {
                let japanese = raw.prefix(1).wholeMatch(of: /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー０-９]/) != nil
                try begin(japanese ? .japanese : .other)
                output += raw
            }
        }
    }
}
