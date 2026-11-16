import Foundation

public enum OrgConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        var parser = OrgParser(lines: TextDecoding.normalizeNewlines(text).components(separatedBy: "\n"))
        // Discover forward declarations before rendering headings or numbering any references.
        parser.context.discovering = true
        _ = parser.render()
        for key in ["TITLE", "SUBTITLE", "AUTHOR", "DATE"] {
            if let value = parser.context.metadata[key] { _ = OrgInline.render(value, context: parser.context) }
        }
        parser.context.discovering = false
        parser.context.anonymous = 0
        parser.index = 0
        var titleBlock = ""
        for (key, tag) in [("TITLE", "h1"), ("SUBTITLE", "p"), ("AUTHOR", "p"), ("DATE", "p")] {
            if let value = parser.context.metadata[key] {
                titleBlock +=
                    "<\(tag) class=\"org-\(key.lowercased())\">\(OrgInline.render(value, context: parser.context))</\(tag)>"
            }
        }
        if !titleBlock.isEmpty { titleBlock = "<header class=\"org-title-block\">\(titleBlock)</header>\n" }
        let body = parser.render() + parser.footnotes()
        return HTMLFragment(body: titleBlock + body, title: parser.context.metadata["TITLE"])
    }
}

struct OrgParser {
    let lines: [String]
    let depth: Int
    private let regionEnds: [Int: Int]
    var index = 0
    let context: OrgContext

    init(lines: [String], depth: Int = 0, context: OrgContext = OrgContext()) {
        self.lines = lines
        self.depth = depth
        self.context = context
        // Pair blocks once, respecting literal regions and same-name nesting.
        var ends: [Int: Int] = [:]
        var stack: [(start: Int, region: DelimitedRegion)] = []
        for (index, line) in lines.enumerated() {
            let marker = line.trimmingCharacters(in: .whitespaces).uppercased()
            if let last = stack.last, marker == last.region.endMarker {
                ends[last.start] = index
                stack.removeLast()
            } else if stack.last?.region.isLiteral != true, let region = Self.region(line) {
                stack.append((index, region))
            }
        }
        regionEnds = ends
    }

    mutating func render(isListItem: Bool = false) -> String {
        // Lists and quote/center blocks share the bound so alternating them cannot bypass it.
        guard depth < 32 else { return "<p>\(HTML.escape(lines.joined(separator: "\n")))</p>\n" }

        var output = ""
        var paragraph: [String] = []
        var caption: String?
        func flush() {
            if !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                let body = isListItem ? renderListContent(text) : inline(text)
                if let caption, paragraph.count == 1, body.hasPrefix("<img "), body.hasSuffix(">"),
                    body.filter({ $0 == "<" }).count == 1
                {
                    output +=
                        "<figure class=\"org-figure org-image\">\(body)<figcaption>\(inline(caption))</figcaption></figure>\n"
                } else {
                    output += "<p>\(body)</p>\n"
                }
                caption = nil
                paragraph = []
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                caption = nil
                index += 1
            } else if let note = orgCaptures(#"^\[fn:([^]:\s]+)\]\s+(.*)$"#, line) {
                flush()
                var definition = [note[1]]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                    orgCaptures(#"^\[fn:([^]:\s]+)\]\s+(.*)$"#, lines[index]) == nil,
                    orgCaptures(#"^(\*+)\s+(.+)$"#, lines[index]) == nil
                {
                    definition.append(lines[index])
                    index += 1
                }
                if context.discovering {
                    context.definitions[note[0]] = definition.joined(separator: "\n")
                    var nested = OrgParser(lines: definition, depth: depth + 1, context: context)
                    _ = nested.render()
                }
                caption = nil
            } else if let region = delimitedRegion(at: index) {
                if let end = endOfRegion(region, after: index) {
                    flush()
                    caption = nil
                    if case .block(let kind, let arguments) = region {
                        output += renderBlock(
                            kind: kind, arguments: arguments, content: Array(lines[(index + 1)..<end]))
                    }
                    index = end + 1
                } else {
                    switch region {
                    case .block:
                        // Preserve incomplete blocks without accidentally consuming the rest of the document.
                        flush()
                        output += "<p>\(HTML.escape(line))</p>\n"
                    case .drawer:
                        paragraph.append(line)
                    }
                    index += 1
                }
            } else if let heading = orgCaptures(#"^(\*+)\s+(.+)$"#, line) {
                flush()
                caption = nil
                let level = min(6, heading[0].count + (context.metadata["TITLE"] == nil ? 0 : 1))
                let done = context.done.contains(
                    heading[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
                let attribute = done ? " class=\"org-done-heading\"" : ""
                output += "<h\(level)\(attribute)>\(renderHeading(heading[1]))</h\(level)>\n"
                index += 1
            } else if let directive = orgCaptures(#"^#\+([A-Za-z_]+):\s*(.*)$"#, trimmed) {
                flush()
                let key = directive[0].uppercased()
                if depth == 0, context.discovering { context.directive(key, value: directive[1]) }
                if key == "CAPTION" {
                    caption = directive[1]
                } else if key != "NAME" && !key.hasPrefix("ATTR_") {
                    caption = nil
                }
                index += 1
            } else if trimmed.hasPrefix("#+") || trimmed.hasPrefix("# ") {
                flush()
                caption = nil
                index += 1
            } else if orgCaptures(#"^-{5,}$"#, trimmed) != nil {
                flush()
                caption = nil
                output += "<hr>\n"
                index += 1
            } else if let planning = OrgInline.planning(trimmed) {
                flush()
                caption = nil
                output += planning
                index += 1
            } else if trimmed == ":" || trimmed.hasPrefix(": ") {
                flush()
                caption = nil
                var fixed: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value == ":" || value.hasPrefix(": ") else { break }
                    fixed.append(value == ":" ? "" : String(value.dropFirst(2)))
                    index += 1
                }
                output += "<pre class=\"org-example\">\(HTML.escape(fixed.joined(separator: "\n")))</pre>\n"
            } else if trimmed.hasPrefix("|") {
                flush()
                let captionHTML = caption.map { inline($0) }
                let table = renderTable()
                if let captionHTML {
                    output +=
                        "<figure class=\"org-figure org-table\"><figcaption>\(captionHTML)</figcaption>"
                        + table.trimmingCharacters(in: .newlines) + "</figure>\n"
                } else {
                    output += table
                }
                caption = nil
            } else if let item = listItem(line) {
                flush()
                caption = nil
                output += renderList(indent: item.indent) + "\n"
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flush()
        return output
    }

    private func renderBlock(kind: String, arguments: String, content: [String]) -> String {
        let text = content.joined(separator: "\n")
        switch kind {
        case "SRC":
            let language = arguments.split(whereSeparator: \.isWhitespace).first.map(String.init)
            if language?.lowercased() == "mermaid" { return MermaidBlock.html(text) }
            let highlighted = language.flatMap { SyntaxHighlighter.highlight(text, language: $0) }
            let attribute =
                language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
            return "<pre><code\(attribute)>\(highlighted ?? HTML.escape(text))</code></pre>\n"
        case "COMMENT", "EXPORT": return ""
        case "EXAMPLE": return "<pre class=\"org-example\">\(HTML.escape(text))</pre>\n"
        case "VERSE": return "<div class=\"org-verse\">\(inline(text))</div>\n"
        case "QUOTE", "CENTER":
            var nested = OrgParser(lines: content, depth: depth + 1, context: context)
            let body = nested.render()
            return kind == "QUOTE" ? "<blockquote>\(body)</blockquote>\n" : "<div class=\"org-center\">\(body)</div>\n"
        default:
            var nested = OrgParser(lines: content, depth: depth + 1, context: context)
            let body = nested.render()
            let name = String(
                kind.lowercased().utf8.filter {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
                }.map { Character(UnicodeScalar($0)) })
            let callout = MarkdownCallouts.Kind(name: name)
            if callout.canonicalName != nil {
                let title =
                    name == "message" ? "" : callout.title(HTML.escape(callout.defaultTitle)) + "\n"
                return callout.opening + "\n" + title + body + "</div>\n"
            }
            return "<div class=\"org-block org-block-\(HTML.escape(name))\">\(body)</div>\n"
        }
    }

    private func renderHeading(_ source: String) -> String {
        var text = source
        var prefix = ""
        var tags = ""
        let keyword = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if context.active.contains(keyword) || context.done.contains(keyword) {
            prefix +=
                "<span class=\"org-\(context.done.contains(keyword) ? "done" : "todo")\">\(HTML.escape(keyword))</span> "
            text = String(text.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        }
        if let match = orgCaptures(#"^(\[#[A-Za-z0-9]\])\s+(.*)$"#, text) {
            prefix += "<span class=\"org-priority\">\(HTML.escape(String(match[0].dropFirst().dropLast())))</span> "
            text = match[1]
        }
        if let match = orgCaptures(#"^(.*?)\s+(:[^\s:]+(?::[^\s:]+)*:)$"#, text) {
            text = match[0]
            tags =
                " <span class=\"org-tags\">"
                + match[1].split(separator: ":").map { "<span class=\"org-tag\">\(HTML.escape(String($0)))</span>" }
                .joined(separator: " ") + "</span>"
        }
        return prefix + inline(text, cookies: .all) + tags
    }

    private mutating func renderTable() -> String {
        var rows: [[String]?] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            if orgCaptures(#"^\|-[\-+]*\|?$"#, line) != nil {
                rows.append(nil)
            } else {
                var content = String(line.dropFirst())
                if content.hasSuffix("|") { content.removeLast() }
                rows.append(content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            index += 1
        }
        var alignments: [Int: String] = [:]
        rows = rows.filter { row in
            guard let row else { return true }
            let nonempty = row.filter { !$0.isEmpty }
            guard !nonempty.isEmpty, nonempty.allSatisfy({ orgCaptures(#"^<([lcr])[0-9]*>$"#, $0) != nil }) else {
                return true
            }
            for (column, cell) in row.enumerated() {
                if let match = orgCaptures(#"^<([lcr])[0-9]*>$"#, cell) { alignments[column] = match[0].lowercased() }
            }
            return false
        }
        let divider = rows.firstIndex(where: { $0 == nil })
        var counts: [Int: (total: Int, numeric: Int)] = [:]
        for (position, row) in rows.enumerated() where divider.map({ position > $0 }) ?? true {
            guard let row else { continue }
            for (column, cell) in row.enumerated() where !cell.isEmpty {
                counts[column, default: (0, 0)].total += 1
                if orgCaptures(#"^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?%?$"#, cell) != nil {
                    counts[column, default: (0, 0)].numeric += 1
                }
            }
        }
        for (column, count) in counts where alignments[column] == nil && count.numeric * 2 >= count.total {
            alignments[column] = "r"
        }
        var head = ""
        var body = ""
        for (rowIndex, row) in rows.enumerated() {
            guard let row else { continue }
            let isHead = divider.map { rowIndex < $0 } ?? false
            let tag = isHead ? "th" : "td"
            let html =
                "<tr>"
                + row.enumerated().map { column, cell in
                    let alignment = alignments[column]
                    let attribute =
                        alignment == "r" ? " align=\"right\"" : (alignment == "c" ? " align=\"center\"" : "")
                    return "<\(tag)\(attribute)>\(inline(cell))</\(tag)>"
                }.joined() + "</tr>"
            if isHead { head += html } else { body += html }
        }
        return "<table>" + (head.isEmpty ? "" : "<thead>\(head)</thead>") + "<tbody>\(body)</tbody></table>\n"
    }

    private struct ListItem {
        let indent: Int
        let number: String?
        let content: String
        var definition: [String]? { orgCaptures(#"^(.*?)\s+::(?:\s+(.*))?$"#, content) }
        var tag: String { definition == nil ? (number == nil ? "ul" : "ol") : "dl" }
    }

    private func listItem(_ line: String) -> ListItem? {
        guard let match = orgCaptures(#"^(\s*)([-+]|[0-9]+[.)])\s+(.*)$"#, line) else { return nil }
        let indent = match[0].reduce(0) { $0 + ($1 == "\t" ? 8 : 1) }
        let number = match[1].first?.isNumber == true ? String(match[1].dropLast()) : nil
        return ListItem(indent: indent, number: number, content: match[2])
    }

    private mutating func renderList(indent: Int) -> String {
        guard index < lines.count, let first = listItem(lines[index]) else { return "" }
        let tag = first.tag
        let start = tag == "ol" ? " start=\"\(first.number ?? "1")\"" : ""
        var output = "<\(tag)\(start)>"
        while index < lines.count, let item = listItem(lines[index]), item.indent == indent, item.tag == tag {
            let definition = item.definition
            let term = definition.map { inline($0[0]) }
            let firstLine = definition?[1] ?? item.content
            index += 1
            let content = [firstLine] + collectListItemContinuation(indent: indent)
            var nested = OrgParser(lines: content, depth: depth + 1, context: context)
            let body = nested.render(isListItem: definition == nil)
            if let term {
                output += "<dt>\(term)</dt><dd>\(body)</dd>"
            } else {
                let task = orgCaptures(#"^\[([ Xx-])\]\s*([\s\S]*)$"#, firstLine) != nil
                output += "<li\(task ? " class=\"task-list-item\"" : "")>\(body)</li>"
            }
        }
        return output + "</\(tag)>"
    }

    private enum DelimitedRegion {
        case block(kind: String, arguments: String)
        case drawer

        var isLiteral: Bool {
            switch self {
            case .drawer: true
            case .block(let kind, _): ["SRC", "EXAMPLE", "VERSE", "COMMENT", "EXPORT"].contains(kind)
            }
        }

        var endMarker: String {
            switch self {
            case .block(let kind, _): "#+END_\(kind)"
            case .drawer: ":END:"
            }
        }
    }

    private func delimitedRegion(at position: Int) -> DelimitedRegion? {
        Self.region(lines[position])
    }

    private static func region(_ source: String) -> DelimitedRegion? {
        let line = source.trimmingCharacters(in: .whitespaces)
        if let block = orgCaptures(#"^#\+BEGIN_([a-z0-9_-]+)(?:\s+(.*))?$"#, line) {
            return .block(kind: block[0].uppercased(), arguments: block[1])
        }
        if let drawer = orgCaptures(#"^:([A-Za-z][A-Za-z0-9_-]*):$"#, line), drawer[0].uppercased() != "END" {
            return .drawer
        }
        return nil
    }

    private func endOfRegion(_ region: DelimitedRegion, after start: Int) -> Int? {
        regionEnds[start]
    }

    private mutating func collectListItemContinuation(indent: Int) -> [String] {
        var continuation: [String] = []
        var contentIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if index + 1 < lines.count, lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    // Leave the separator unconsumed so the outer item loop also ends this list.
                    break
                }
                continuation.append(line)
                index += 1
                continue
            }

            let leading = indentation(of: line)
            guard leading > indent else { break }
            contentIndent = min(contentIndent ?? leading, leading)
            if let region = delimitedRegion(at: index), let end = endOfRegion(region, after: index) {
                // Region contents cannot end an item or determine its structural indentation.
                continuation.append(contentsOf: lines[index...end])
                index = end + 1
            } else {
                continuation.append(line)
                index += 1
            }
        }
        return continuation.map { removingIndent(contentIndent ?? 0, from: $0) }
    }

    private func indentation(of line: String) -> Int {
        line.prefix(while: \.isWhitespace).reduce(0) { $0 + ($1 == "\t" ? 8 : 1) }
    }

    private func removingIndent(_ count: Int, from line: String) -> String {
        var columns = 0
        var end = line.startIndex
        while end < line.endIndex, line[end].isWhitespace, columns < count {
            columns += line[end] == "\t" ? 8 : 1
            end = line.index(after: end)
        }
        return String(repeating: " ", count: max(0, columns - count)) + line[end...]
    }

    private func renderListContent(_ content: String) -> String {
        if let checkbox = orgCaptures(#"^\[([ Xx-])\]\s*([\s\S]*)$"#, content) {
            let attribute = checkbox[0] == "-" ? " class=\"org-partial\"" : (checkbox[0] == " " ? "" : " checked")
            return "<input type=\"checkbox\" disabled\(attribute)>\(inline(checkbox[1], cookies: .edges))"
        }
        return inline(content, cookies: .edges)
    }
    private func inline(_ text: String, cookies: OrgInline.Cookies = .none) -> String {
        OrgInline.render(text, context: context, depth: depth, cookies: cookies)
    }

    func footnotes() -> String {
        var items = ""
        var position = 0
        while position < context.order.count {
            let label = context.order[position]
            var nested = OrgParser(
                lines: (context.definitions[label] ?? "").components(separatedBy: "\n"),
                depth: (context.noteDepths[label] ?? depth) + 1, context: context)
            items += "<li id=\"fn-\(position + 1)\">\(nested.render())</li>\n"
            position += 1
        }
        return items.isEmpty ? "" : "<section class=\"footnotes\">\n<ol>\n\(items)</ol>\n</section>\n"
    }

}
