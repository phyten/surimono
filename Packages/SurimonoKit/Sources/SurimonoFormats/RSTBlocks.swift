import Foundation

extension RSTDocument {
    func blocks(_ lines: [String], classes: [String] = []) -> String {
        guard depth < 48 else {
            issueCount += 1
            return "<pre>\(HTML.escape(lines.joined(separator: "\n")))</pre>"
        }
        depth += 1
        defer { depth -= 1 }
        return RSTBlockReader(lines: lines, document: self, classes: classes).read()
    }
}

/// Each invocation consumes a single indentation level. A child reader receives only the lines of its enclosing block.
final class RSTBlockReader {
    let lines: [String]
    let document: RSTDocument
    private let classes: [String]
    var index = 0
    private var parts: [RSTDocument.Part] = []
    lazy var simpleEnds = indexSimpleTables()

    init(lines: [String], document: RSTDocument, classes: [String] = []) {
        self.classes = classes
        self.lines = lines
        self.document = document
    }

    static func blank(_ line: String) -> Bool { line.utf8.allSatisfy { $0 == 32 || $0 == 9 } }

    func read() -> String {
        document.assemble(readParts())
    }

    private func readParts() -> [RSTDocument.Part] {
        while index < lines.count {
            let first = lines[index]
            if Self.blank(first) {
                index += 1
                continue
            }
            var attributes = RSTDocument.Attributes(classes: [], targets: [])
            swap(&attributes.classes, &document.directives.nextClasses)
            swap(&attributes.targets, &document.references.pendingTargets)
            if document.depth == 1, let (style, title, consumed) = heading(at: index) {
                attributes.classes.insert(contentsOf: classes, at: 0)
                parts.append(document.heading(adornment: style, text: title, attributes: attributes))
                index += consumed
                continue
            }
            if field(first) != nil {
                attributes.classes.insert(contentsOf: classes, at: 0)
                parts.append(.fields(fields(), attributes: attributes))
                continue
            }
            if first.lowercased().hasPrefix(".. include::") {
                let start = index
                index += 1
                let child = indented()
                if document.readNormalInclude(
                    first, body: child,
                    { nested in
                        document.directives.nextClasses = attributes.classes
                        document.references.pendingTargets = attributes.targets
                        parts += RSTBlockReader(lines: nested, document: document, classes: classes).readParts()
                    })
                {
                    continue
                }
                index = start
            }
            let output = body(first)
            if output.isEmpty {
                attributes.classes.append(contentsOf: document.directives.nextClasses)
                attributes.targets.append(contentsOf: document.references.pendingTargets)
                document.directives.nextClasses = attributes.classes
                document.references.pendingTargets = attributes.targets
            } else {
                attributes.classes.insert(contentsOf: classes, at: 0)
                let styled = document.applyDirectiveClasses(attributes.classes, to: output)
                parts.append(.body(document.rstAttachTargets(attributes.targets, to: styled)))
            }
        }
        return parts
    }

    private func body(_ first: String) -> String {
        if first.first == " " { return quote() }
        if first == ".." || first.hasPrefix(".. ") || first == "__" || first.hasPrefix("__ ") {
            index += 1
            let separated = index < lines.count && Self.blank(lines[index])
            let body = indented()
            if let explicit = document.renderExplicit(first, body: body) { return explicit }
            let directiveBody = separated && !body.isEmpty ? [""] + body : body
            return document.renderDirective(first, body: directiveBody) ?? ""
        }
        if first.hasPrefix(">>> ") || first == ">>>" {
            return "<pre class=\"doctest-block\">\(HTML.escape(nonblank().joined(separator: "\n")))</pre>"
        }
        if let html = table() { return html }
        if first == "|" || first.hasPrefix("| ") { return lineBlock() }
        if let marker = listMarker(first), startsList(marker) { return list(marker) }
        if option(first) != nil { return options() }
        if let over = Self.adornment(first), over.count >= 4, index + 2 < lines.count,
            !Self.blank(lines[index + 1]), let under = Self.adornment(lines[index + 2]), under != over
        {
            let start = index
            index += 3
            document.issueCount += 1
            return "<pre>\(HTML.escape(lines[start..<index].joined(separator: "\n")))</pre>"
        }
        if let mark = Self.adornment(first), mark.count >= 4, index + 1 == lines.count || Self.blank(lines[index + 1]) {
            index += 1
            return "<hr>"
        }
        if !first.hasSuffix("::"), listMarker(first) == nil, index + 1 < lines.count, lines[index + 1].rstIndent > 0,
            !Self.blank(lines[index + 1])
        {
            return definitions()
        }
        return paragraph()
    }

    static func adornment(_ line: String) -> String? {
        let mark = line.rstStripped
        guard let first = mark.utf8.first, first > 32, first < 127,
            !(48...57).contains(first), !(65...90).contains(first), !(97...122).contains(first),
            mark.utf8.allSatisfy({ $0 == first })
        else { return nil }
        return mark
    }

    private func heading(at i: Int) -> (String, String, Int)? {
        guard i + 1 < lines.count, lines[i].first != " ", !Self.blank(lines[i + 1]) else { return nil }
        if let over = Self.adornment(lines[i]), i + 2 < lines.count, over == lines[i + 2].rstStripped,
            !Self.blank(lines[i + 1]), over.count >= 4 || over.count >= lines[i + 1].rstStripped.count,
            let first = over.first
        {
            return ("over" + String(first), lines[i + 1].rstStripped, 3)
        }
        guard let under = Self.adornment(lines[i + 1]), let first = under.first,
            lines[i + 1].first != " ", under.count >= 4 || under.count >= lines[i].rstStripped.count,
            Self.adornment(lines[i]) == nil
        else { return nil }
        return (String(first), lines[i].rstStripped, 2)
    }

    func nonblank() -> [String] {
        let start = index
        while index < lines.count, !Self.blank(lines[index]) { index += 1 }
        return Array(lines[start..<index])
    }

    /// Blank lines belong to the child only when more indented material follows them.
    func indented(minimum: Int = 1, strip fixed: Int? = nil) -> [String] {
        let start = index
        var end = start
        var indent = Int.max
        while index < lines.count {
            let line = lines[index]
            if !Self.blank(line) {
                let amount = line.rstIndent
                guard amount >= minimum else { break }
                indent = min(indent, amount)
                end = index + 1
            }
            index += 1
        }
        guard start < end else { return [] }
        var first = start
        while first < end, Self.blank(lines[first]) { first += 1 }
        return lines[first..<end].map { String($0.dropFirst(fixed ?? indent)) }
    }

    private func paragraph() -> String {
        let start = index
        index += 1
        while index < lines.count, !Self.blank(lines[index]), lines[index].rstIndent == 0 { index += 1 }
        var text = lines[start..<index].map(\.rstStripped).joined(separator: "\n")
        if text.hasSuffix("::") {
            if text == "::" {
                text = ""
            } else if text.hasSuffix(" ::") {
                text.removeLast(3)
            } else {
                text.removeLast()
            }
            var next = index
            while next < lines.count, Self.blank(lines[next]) { next += 1 }
            var literal: [String] = []
            if next < lines.count {
                if lines[next].rstIndent > 0 {
                    index = next
                    literal = indented()
                } else if let marker = lines[next].first, let ascii = marker.asciiValue, ascii > 32, ascii < 127,
                    !marker.isLetter, !marker.isNumber
                {
                    index = next
                    while index < lines.count, lines[index].first == marker {
                        literal.append(lines[index])
                        index += 1
                    }
                }
            }
            if !literal.isEmpty {
                let p = text.isEmpty ? "" : "<p>\(document.inline(text))</p>"
                return p + "<pre class=\"literal-block\">\(HTML.escape(literal.joined(separator: "\n")))</pre>"
            }
            document.issueCount += 1
            text = lines[start..<index].joined(separator: "\n")
        }
        return "<p>\(document.inline(text))</p>"
    }

    private func quote() -> String {
        let source = indented()
        var pieces: [String] = []
        var rest: [String] = []
        var cursor = 0
        while cursor < source.count {
            let line = source[cursor]
            cursor += 1
            if let prefix = ["--- ", "-- ", "— ", "—"].first(where: { line.hasPrefix($0) }),
                rest.last.map(Self.blank) ?? false
            {
                pieces.append(document.blocks(rest))
                var author = String(line.dropFirst(prefix.count))
                while cursor < source.count, source[cursor].rstIndent > 0, !Self.blank(source[cursor]) {
                    author += "\n" + source[cursor].rstStripped
                    cursor += 1
                }
                pieces.append("<p class=\"attribution\">—\(document.inline(author))</p>")
                rest = []
            } else {
                rest.append(line)
            }
        }
        pieces.append(document.blocks(rest))
        return "<blockquote>\(pieces.joined())</blockquote>"
    }

    private func lineBlock() -> String {
        var items: [(Int, String)] = []
        var inherited = 0
        while index < lines.count, lines[index] == "|" || lines[index].hasPrefix("| ") {
            let text = String(lines[index].dropFirst(2))
            let indent = text.isEmpty ? inherited : text.rstIndent
            var content = text.rstStripped
            index += 1
            while index < lines.count, lines[index].rstIndent > 0, !Self.blank(lines[index]) {
                content += "\n" + lines[index].rstStripped
                index += 1
            }
            items.append((indent, content))
            inherited = indent
        }
        var levels = [0]
        var html = "<div class=\"line-block rst-line-block\">"
        for (indent, content) in items {
            while levels.count > 1, let last = levels.last, last > indent {
                levels.removeLast()
                html += "</div>"
            }
            if indent > levels.last ?? 0 {
                levels.append(indent)
                html += "<div class=\"line-block rst-line-block\">"
            }
            html += "<div class=\"line\">\(document.inline(content))</div>"
        }
        return html + String(repeating: "</div>", count: levels.count)
    }

    private func definitions() -> String {
        var html = "<dl>"
        while index + 1 < lines.count, !Self.blank(lines[index]), lines[index].rstIndent == 0,
            lines[index + 1].rstIndent > 0, !Self.blank(lines[index + 1]), listMarker(lines[index]) == nil,
            !lines[index].hasPrefix(".. "), field(lines[index]) == nil, option(lines[index]) == nil
        {
            let terms = lines[index].components(separatedBy: " : ")
            html += "<dt>" + document.inline(terms[0])
            for classifier in terms.dropFirst() {
                html += "<span class=\"classifier rst-classifier\">\(document.inline(classifier))</span>"
            }
            index += 1
            html += "</dt><dd>\(document.blocks(indented()))</dd>"
        }
        return html + "</dl>"
    }
}
