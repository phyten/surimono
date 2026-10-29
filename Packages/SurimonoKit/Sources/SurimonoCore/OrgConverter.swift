import Foundation

public enum OrgConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        var parser = OrgParser(lines: TextDecoding.normalizeNewlines(text).components(separatedBy: "\n"))
        let body = parser.render()
        var titleBlock = ""
        for (key, tag) in [("TITLE", "h1"), ("AUTHOR", "p"), ("DATE", "p")] {
            if let value = parser.metadata[key] {
                titleBlock += "<\(tag) class=\"org-\(key.lowercased())\">\(OrgInline.render(value))</\(tag)>"
            }
        }
        if !titleBlock.isEmpty { titleBlock = "<header class=\"org-title-block\">\(titleBlock)</header>\n" }
        return HTMLFragment(body: titleBlock + body, title: parser.metadata["TITLE"])
    }
}

private struct OrgParser {
    let lines: [String]
    var index = 0
    var metadata: [String: String] = [:]

    mutating func render(isListItem: Bool = false) -> String {
        var output = ""
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                let body = isListItem ? renderListContent(text) : OrgInline.render(text)
                output += "<p>\(body)</p>\n"
                paragraph = []
            }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                index += 1
            } else if let region = delimitedRegion(at: index) {
                if let end = endOfRegion(region, after: index) {
                    flush()
                    if case .block(let kind, let arguments) = region {
                        output += renderBlock(
                            kind: kind, arguments: arguments, content: Array(lines[(index + 1)..<end]),
                            original: Array(lines[index...end]))
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
            } else if let heading = captures(#"^(\*+)\s+(.+)$"#, line) {
                flush()
                let level = min(6, heading[0].count)
                output += "<h\(level)>\(renderHeading(heading[1]))</h\(level)>\n"
                index += 1
            } else if let directive = captures(#"^#\+([A-Za-z_]+):\s*(.*)$"#, trimmed) {
                flush()
                let key = directive[0].uppercased()
                if ["TITLE", "AUTHOR", "DATE"].contains(key) { metadata[key] = directive[1] }
                index += 1
            } else if trimmed.hasPrefix("#+") || trimmed.hasPrefix("# ") {
                flush()
                index += 1
            } else if captures(#"^-{5,}$"#, trimmed) != nil {
                flush()
                output += "<hr>\n"
                index += 1
            } else if trimmed.hasPrefix("SCHEDULED:") || trimmed.hasPrefix("DEADLINE:") {
                flush()
                output += "<small class=\"org-planning\">\(HTML.escape(trimmed))</small>\n"
                index += 1
            } else if trimmed.hasPrefix("|") {
                flush()
                output += renderTable()
            } else if let item = listItem(line) {
                flush()
                output += renderList(indent: item.indent) + "\n"
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flush()
        return output
    }

    private func renderBlock(kind: String, arguments: String, content: [String], original: [String]) -> String {
        let text = content.joined(separator: "\n")
        switch kind {
        case "SRC":
            let language = arguments.split(whereSeparator: \.isWhitespace).first.map(String.init)
            let highlighted = language.flatMap { SyntaxHighlighter.highlight(text, language: $0) }
            let attribute =
                language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
            return "<pre><code\(attribute)>\(highlighted ?? HTML.escape(text))</code></pre>\n"
        case "EXAMPLE": return "<pre>\(HTML.escape(text))</pre>\n"
        case "VERSE": return "<div class=\"org-verse\">\(OrgInline.render(text))</div>\n"
        case "QUOTE", "CENTER":
            var nested = OrgParser(lines: content)
            let body = nested.render()
            return kind == "QUOTE" ? "<blockquote>\(body)</blockquote>\n" : "<div class=\"org-center\">\(body)</div>\n"
        default:
            return "<pre>\(HTML.escape(original.joined(separator: "\n")))</pre>\n"
        }
    }

    private func renderHeading(_ source: String) -> String {
        var text = source
        var prefix = ""
        var tags = ""
        if let match = captures(#"^(TODO|DONE)\s+(.*)$"#, text) {
            prefix += "<span class=\"org-\(match[0] == "DONE" ? "done" : "todo")\">\(match[0])</span> "
            text = match[1]
        }
        if let match = captures(#"^(\[#[A-Za-z0-9]\])\s+(.*)$"#, text) {
            prefix += "<span class=\"org-priority\">\(HTML.escape(match[0]))</span> "
            text = match[1]
        }
        if let match = captures(#"^(.*?)\s+(:[^\s:]+(?::[^\s:]+)*:)$"#, text) {
            text = match[0]
            tags =
                " "
                + match[1].split(separator: ":").map { "<span class=\"org-tag\">\(HTML.escape(String($0)))</span>" }
                .joined(separator: " ")
        }
        return prefix + OrgInline.render(text) + tags
    }

    private mutating func renderTable() -> String {
        var rows: [[String]?] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            if captures(#"^\|-[\-+]*\|?$"#, line) != nil {
                rows.append(nil)
            } else {
                var content = String(line.dropFirst())
                if content.hasSuffix("|") { content.removeLast() }
                rows.append(content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            index += 1
        }
        let divider = rows.firstIndex(where: { $0 == nil })
        var head = ""
        var body = ""
        for (rowIndex, row) in rows.enumerated() {
            guard let row else { continue }
            let isHead = divider.map { rowIndex < $0 } ?? false
            let tag = isHead ? "th" : "td"
            let html = "<tr>" + row.map { "<\(tag)>\(OrgInline.render($0))</\(tag)>" }.joined() + "</tr>"
            if isHead { head += html } else { body += html }
        }
        return "<table>" + (head.isEmpty ? "" : "<thead>\(head)</thead>") + "<tbody>\(body)</tbody></table>\n"
    }

    private struct ListItem {
        let indent: Int
        let number: String?
        let content: String
        var definition: [String]? { captures(#"^(.*?)\s+::(?:\s+(.*))?$"#, content) }
        var tag: String { definition == nil ? (number == nil ? "ul" : "ol") : "dl" }
    }

    private func listItem(_ line: String) -> ListItem? {
        guard let match = captures(#"^(\s*)([-+]|[0-9]+[.)])\s+(.*)$"#, line) else { return nil }
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
            let firstLine = definition?[1] ?? item.content
            index += 1
            let content = [firstLine] + collectListItemContinuation(indent: indent)
            var nested = OrgParser(lines: content)
            let body = nested.render(isListItem: definition == nil)
            if let definition {
                output += "<dt>\(OrgInline.render(definition[0]))</dt><dd>\(body)</dd>"
            } else {
                output += "<li>\(body)</li>"
            }
        }
        return output + "</\(tag)>"
    }

    private enum DelimitedRegion {
        case block(kind: String, arguments: String)
        case drawer

        var endMarker: String {
            switch self {
            case .block(let kind, _): "#+END_\(kind)"
            case .drawer: ":END:"
            }
        }
    }

    private func delimitedRegion(at position: Int) -> DelimitedRegion? {
        let line = lines[position].trimmingCharacters(in: .whitespaces)
        if let block = captures(#"^#\+BEGIN_(\w+)(?:\s+(.*))?$"#, line) {
            return .block(kind: block[0].uppercased(), arguments: block[1])
        }
        if let drawer = captures(#"^:([A-Za-z][A-Za-z0-9_-]*):$"#, line), drawer[0].uppercased() != "END" {
            return .drawer
        }
        return nil
    }

    private func endOfRegion(_ region: DelimitedRegion, after start: Int) -> Int? {
        ((start + 1)..<lines.count).first {
            lines[$0].trimmingCharacters(in: .whitespaces).uppercased() == region.endMarker
        }
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
        if let checkbox = captures(#"^\[([ Xx-])\]\s*([\s\S]*)$"#, content) {
            let state = checkbox[0] == " " ? "unchecked" : (checkbox[0] == "-" ? "partial" : "checked")
            let symbol = state == "unchecked" ? "☐" : (state == "partial" ? "◩" : "☑")
            return "<span class=\"org-checkbox \(state)\">\(symbol)</span> \(OrgInline.render(checkbox[1]))"
        }
        return OrgInline.render(content)
    }
}

private func captures(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
}

private enum OrgInline {
    static func render(_ text: String) -> String {
        let characters = Array(text)
        let tags: [Character: String] = ["*": "strong", "/": "em", "_": "u", "=": "code", "~": "code", "+": "del"]
        var output = ""
        var index = 0
        var linkSearchExhausted = false
        while index < characters.count {
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
                let label = parts.count > 1 ? parts.dropFirst().joined(separator: "][") : destination
                let path = destination.components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                let suffix = (path as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff", "heic"].contains(suffix) {
                    output += "<img src=\"\(HTML.escape(destination))\" alt=\"\(HTML.escape(label))\">"
                } else {
                    output += "<a href=\"\(HTML.escape(destination))\">\(render(label))</a>"
                }
                index = end + 2
                continue
            }
            let character = characters[index]
            if let tag = tags[character], index + 1 < characters.count, !characters[index + 1].isWhitespace,
                index == 0 || characters[index - 1].isWhitespace || "([{'\"".contains(characters[index - 1]),
                let end = ((index + 2)..<characters.count).first(where: {
                    characters[$0] == character && !characters[$0 - 1].isWhitespace
                        && ($0 + 1 == characters.count || characters[$0 + 1].isWhitespace
                            || ")]},.!?;:'\"".contains(characters[$0 + 1]))
                })
            {
                let inner = String(characters[(index + 1)..<end])
                output += "<\(tag)>\(tag == "code" ? HTML.escape(inner) : render(inner))</\(tag)>"
                index = end + 1
            } else {
                output += HTML.escape(String(character))
                index += 1
            }
        }
        return output
    }
}
