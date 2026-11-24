import Foundation

/// The compositor receives finished HTML. Only prose text is eligible for vertical glyph treatment.
package enum VerticalText {
    package static let openingMarks = "「『（〔［｛〈《【〖〘〚"
    package static let closingMarks = "」』）〕］｝〉》】〗〙〛、。，．"

    package enum MarkupError: Error { case tooManySpans }

    package static func marked(_ html: String, latex: Bool = false) throws -> String {
        var writer = Writer()
        writer.output.reserveCapacity(html.utf8.count)
        var skipped: (name: String, depth: Int)?
        var plain = false
        var note = false
        var heading = false
        var numberDepth = 0
        var runBoundary: Int?
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
                        var i = index + direction
                        return AnyIterator<Substring> {
                            // A section number and its title are separate runs even without intervening HTML text.
                            while numberDepth == 0 && tokens.indices.contains(i) && i != runBoundary {
                                let token = tokens[i]
                                i += direction
                                switch token {
                                case .text(let neighbor): return VerticalTextSource(neighbor).text[...]
                                case .tag(let tag)
                                where !inlineElements.contains(tag.name) || tag.name == "ruby" || tag.name == "sup":
                                    return nil
                                case .tag(let tag) where !tag.isClosing && tag.name == "span":
                                    let classes = tag.attribute("class")?.split(whereSeparator: \.isWhitespace) ?? []
                                    if classes.contains("explicit-tcy") || classes.contains("tcy") { return nil }
                                default: continue
                                }
                            }
                            return nil
                        }
                    }
                }
            case .tag(let tag):
                if let current = skipped {
                    writer.markup(tag.source)
                    if current.name == tag.name && !tag.isSelfClosing {
                        let depth = current.depth + (tag.isClosing ? -1 : 1)
                        skipped = depth == 0 ? nil : (current.name, depth)
                        if depth == 0 && current.name == "span" { runBoundary = index }
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
                if tag.name == "sup" {
                    let isReference = !tag.isClosing && classes.contains("footnote-ref")
                    // A shoulder annotation contributes no inter-script spacing to the surrounding prose.
                    if isReference || note { try writer.begin(.other) }
                    note = isReference
                }
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
                            runBoundary = index
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
                ["math-block", "math-display", "mermaid-block", "graphviz-block", "plantuml-block"]
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
                ["explicit-tcy", "tcy", "upright-digit", "aki", "v-half", "v-close", "v-before-open", "v-pair-space"]
                    .contains($0)
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
                let text = VerticalTextSource(source).text
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
        private var closingMark: Character?
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

        private mutating func span(_ name: String, _ source: String, pair: String? = nil) throws -> String {
            guard remaining > 0 else { throw MarkupError.tooManySpans }
            remaining -= 1
            let marks = pair.map { " data-pair=\"\($0)\"" } ?? ""
            return "<span class=\"\(name)\"\(marks)>\(source)</span>"
        }

        mutating func text(
            _ html: String, plain: Bool, note: Bool, headingNumber: Bool, neighbor: (Int) -> AnyIterator<Substring>
        ) throws {
            let node = VerticalTextSource(html)
            let source = node.text
            let token =
                #/
                [+-]?[\p{sc=Latin}0-9_]+(?:[.,:/+\-][0-9][\p{sc=Latin}0-9_]*)* %? | \.[0-9]+ %?
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
            let address = #/(?:[\p{L}\p{N}\-]+\.)*[A-Za-z0-9\u{fffc}%._~:/?#\[\]@!$&'()*+,;=\-]+/#
            var rest = source[...]
            while !rest.isEmpty {
                var host = hosts[rest.startIndex]
                if host == nil, let first = rest.first, "wWmM".contains(first) {
                    host = rest.prefixMatch(of: /(?i:www\.|mailto:)/)?.range.upperBound
                }
                if let host, let match = rest[host...].prefixMatch(of: address) {
                    try url(rest[..<match.range.upperBound], in: node)
                    rest = rest[match.range.upperBound...]
                    continue
                }
                // Short ASCII words and standalone punctuation are common in source-like prose.
                // Avoid starting a Unicode regex VM (and two script lookups) for every period.
                let prefix = rest.prefix { $0.isASCII && $0.isLetter }
                let tail = rest[prefix.endIndex...]
                var raw: Substring
                if !prefix.isEmpty, tail.first.map({ $0.isASCII && !$0.isNumber && !"_%,:/+-".contains($0) }) ?? true,
                    !(tail.first == "." && tail.dropFirst().first?.isNumber == true)
                {
                    raw = prefix
                } else if rest.first == ".", rest.dropFirst().first?.isNumber != true {
                    raw = rest.prefix(1)
                } else {
                    raw = rest.prefixMatch(of: token)?.output ?? rest.prefix(1)
                }
                var hasUnit = false
                if raw.last?.isASCII == true, raw.last?.isNumber == true, !note {
                    let suffix = source[raw.endIndex...]
                    let after = suffix.first ?? neighbor(1).next()?.first
                    if after?.isHorizontalSpace == true {
                        let symbol = Self.followingUnit(in: suffix, neighbors: neighbor(1))
                        hasUnit = symbol != nil
                        if let symbol, suffix.first?.isHorizontalSpace == true {
                            let local = suffix.drop(while: \.isHorizontalSpace).prefix { $0.isUnitLetter }
                            if local == symbol { raw = rest[..<local.endIndex] }
                        }
                    }
                }
                let original = node.original(raw)
                if plain && raw.first?.isNewline == true {
                    try begin(.paragraph)
                    output += original
                } else if raw.first == " " || raw.first?.isNewline == true {
                    pending.append((original, true))
                    hasSpace = true
                } else {
                    let digits = raw.utf8.count <= 2 && raw.utf8.allSatisfy { (48...57).contains($0) }
                    if digits {
                        let before =
                            raw.startIndex == source.startIndex
                            ? neighbor(-1).next()?.last : source[source.index(before: raw.startIndex)]
                        let after =
                            raw.endIndex == source.endIndex ? neighbor(1).next()?.first : source[raw.endIndex]
                        let touchesWord = [before, after].compactMap { $0 }.contains {
                            $0.isASCII && ($0.isLetter || $0.isNumber || "%.,_+/-:".contains($0))
                        }
                        if note || (!touchesWord && !hasUnit) {
                            try begin(.other)
                            output += try span(
                                headingNumber || raw.count == 2 ? "tcy" : "upright-digit", original)
                        } else {
                            try western(original)
                        }
                    } else {
                        try glyphs(raw, original: original)
                    }
                }
                rest = rest[raw.endIndex...]
            }
        }

        // A unit can start in the next emphasis or link. Stop at the end of its symbol,
        // so a space followed by ordinary English prose leaves the integer independent.
        private static func followingUnit(in suffix: Substring, neighbors: AnyIterator<Substring>) -> String? {
            var part = suffix
            var symbol = ""
            while true {
                if symbol.isEmpty { part = part.drop(while: \.isHorizontalSpace) }
                let letters = part.prefix(17).prefix { $0.isUnitLetter }
                guard letters.utf8.count + symbol.utf8.count <= 16 else { return nil }
                symbol += letters
                guard letters.endIndex == part.endIndex, let next = neighbors.next() else { break }
                part = next
            }
            return LaTeXUnits.printedSymbols.contains(symbol) ? symbol : nil
        }

        mutating func url(_ source: String) throws {
            let node = VerticalTextSource(source)
            try url(node.text[...], in: node)
        }

        private mutating func url(_ label: Substring, in node: VerticalTextSource) throws {
            var body = ""
            var start = label.startIndex
            for index in label.indices where "/.-_?&=#".contains(label[index]) {
                let end = label.index(after: index)
                body += node.original(label[start..<end])
                guard remaining > 0 else { throw MarkupError.tooManySpans }
                remaining -= 1
                body += "<wbr>"
                start = end
            }
            body += node.original(label[start...])
            try begin(.western)
            output += try span("v-latin v-url", body)
        }

        mutating func western(_ source: String) throws {
            try begin(.western)
            output += try span("v-latin", source)
        }

        private mutating func glyphs(_ raw: Substring, original: String) throws {
            guard let first = raw.first else { return }
            if VerticalText.openingMarks.contains(first) {
                let atParagraph = last == .paragraph
                let pair = hasSpace || closing == nil ? nil : closingMark.map { String($0) + String(first) }
                let trim = !hasSpace && [.start, .paragraph, .opening, .closing].contains(last)
                try begin(.opening)
                // A break can fall after the collapsible half space. Keep the negative margin
                // on the glyph itself so it follows the bracket onto its new line.
                if !trim { output += try span("v-before-open", "") }
                if let pair { output += try span("v-pair-space", "", pair: pair) }
                output += try span(atParagraph ? "v-half v-initial" : "v-half", original)
            } else if VerticalText.closingMarks.contains(first) {
                try begin(.closing)
                closing = original
                closingMark = first
            } else if raw.utf8.count == 2 && (first == "!" || first == "?") {
                try begin(.other)
                output += try span("tcy", original)
            } else if first.isASCII
                && (first.isLetter || first.isNumber || ("+-._".contains(first) && raw.utf8.count > 1))
                || !first.isASCII && raw.prefix(1).wholeMatch(of: /\p{sc=Latin}/) != nil
            {
                try western(original)
            } else {
                let japanese =
                    !first.isASCII
                    && raw.prefix(1).wholeMatch(of: /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー０-９]/) != nil
                try begin(japanese ? .japanese : .other)
                output += original
            }
        }
    }
}

extension Character {
    fileprivate var isUnitLetter: Bool { isASCII && isLetter || "%µΩ°Å".contains(self) }
    fileprivate var isHorizontalSpace: Bool { self == " " || self == "\t" || self == "\u{00a0}" }
}
