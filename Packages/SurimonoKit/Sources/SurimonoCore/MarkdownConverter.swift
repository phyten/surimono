import Foundation
import Markdown

public enum MarkdownConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        var lines = TextDecoding.normalizeNewlines(text).components(separatedBy: "\n")
        var title: String?
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] where line.hasPrefix("title:") {
                var value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                    value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'"
                {
                    value = String(value.dropFirst().dropLast())
                }
                title = value
            }
            lines.removeFirst(end + 1)
        }
        let source = MarkdownCallouts.preprocess(lines)
        let document = Document(parsing: source, options: [.disableSmartOpts])
        if title == nil { title = firstHeading(in: document) }
        return HTMLFragment(body: render(document, sourceLines: source.components(separatedBy: "\n")), title: title)
    }

    private static func firstHeading(in node: any Markup) -> String? {
        if let heading = node as? Heading, heading.level == 1 { return heading.plainText }
        for child in node.children {
            if let title = firstHeading(in: child) { return title }
        }
        return nil
    }

    // Render from the AST because HTMLFormatter does not escape text or attributes.
    private static func render(_ node: any Markup, sourceLines: [String], autolinks: Bool = true) -> String {
        func children(allowLinks: Bool? = nil) -> String {
            renderChildren(node, sourceLines: sourceLines, autolinks: allowLinks ?? autolinks)
        }
        func wrap(_ tag: String) -> String { "<\(tag)>\(children())</\(tag)>" }
        switch node {
        case let text as Text: return autolinks ? renderAutolinks(text.string) : HTML.escape(text.string)
        case let code as InlineCode: return "<code>\(HTML.escape(code.code))</code>"
        case let code as CodeBlock:
            let highlighted = code.language.flatMap { SyntaxHighlighter.highlight(code.code, language: $0) }
            let language =
                code.language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
            return "<pre><code\(language)>\(highlighted ?? HTML.escape(code.code))</code></pre>\n"
        case let heading as Heading: return wrap("h\(heading.level)") + "\n"
        case is Paragraph: return wrap("p") + "\n"
        case is Strong: return wrap("strong")
        case is Emphasis: return wrap("em")
        case is Strikethrough: return wrap("del")
        case let quote as BlockQuote:
            return renderCallout(quote, sourceLines: sourceLines, autolinks: autolinks) ?? (wrap("blockquote") + "\n")
        case is ThematicBreak: return "<hr>\n"
        case is LineBreak: return "<br>\n"
        case is SoftBreak: return "\n"
        case let html as HTMLBlock: return html.rawHTML
        case let html as InlineHTML: return html.rawHTML
        case let link as Link:
            let title = link.title.map { " title=\"\(HTML.escape($0))\"" } ?? ""
            return "<a href=\"\(HTML.escape(link.destination ?? ""))\"\(title)>\(children(allowLinks: false))</a>"
        case let image as Image:
            let title = image.title.map { " title=\"\(HTML.escape($0))\"" } ?? ""
            return "<img src=\"\(HTML.escape(image.source ?? ""))\" alt=\"\(HTML.escape(image.plainText))\"\(title)>"
        case let list as OrderedList:
            return
                "<ol start=\"\(list.startIndex)\">\(renderItems(of: list, sourceLines: sourceLines, autolinks: autolinks))</ol>\n"
        case let list as UnorderedList:
            return "<ul>\(renderItems(of: list, sourceLines: sourceLines, autolinks: autolinks))</ul>\n"
        case let table as Table: return renderTable(table, sourceLines: sourceLines)
        default: return children()
        }
    }

    private static func renderCallout(_ quote: BlockQuote, sourceLines: [String], autolinks: Bool) -> String? {
        // Text nodes have already decoded escapes and entities, so only a literal source marker opts in.
        guard let paragraph = quote.child(at: 0) as? Paragraph,
            let start = paragraph.range?.lowerBound,
            start.line > 0, start.line <= sourceLines.count, start.column > 0
        else { return nil }
        let source = String(Substring(sourceLines[start.line - 1].utf8.dropFirst(start.column - 1)))
        // A label followed by a colon is a link reference definition, which cmark drops from the paragraph without
        // moving its start; the marker below would then come from a later, possibly escaped, line. A valid kind name
        // has no brackets or backslashes, so its closing bracket is the one that would end such a label. cmark reads
        // the colon as a byte, whereas a Character would merge it with a following combining mark.
        guard MarkdownCallouts.quoteMarker(source) != nil, let close = source.firstIndex(of: "]"),
            source[source.index(after: close)...].utf8.first != UInt8(ascii: ":")
        else { return nil }
        let inline = Array(paragraph.children)
        let breakIndex = inline.firstIndex { $0 is SoftBreak || $0 is LineBreak } ?? inline.count
        let firstLine = inline[..<breakIndex]
        // cmark may split the bracket marker across adjacent Text nodes.
        let prefix = firstLine.prefix { $0 is Text }.compactMap { ($0 as? Text)?.string }.joined()
        guard let marker = MarkdownCallouts.quoteMarker(prefix) else { return nil }
        var remaining = marker.consumed
        var titleNodes: [any InlineMarkup] = []
        for node in firstLine {
            if let text = node as? Text, remaining > 0 {
                let skipped = min(remaining, text.string.count)
                remaining -= skipped
                let suffix = String(text.string.dropFirst(skipped))
                if !suffix.isEmpty { titleNodes.append(Text(suffix)) }
            } else if let node = node as? any InlineMarkup {
                titleNodes.append(node)
            }
        }
        let title = renderChildren(Paragraph(titleNodes), sourceLines: sourceLines, autolinks: autolinks)
        let titleHTML = title.isEmpty ? HTML.escape(marker.kind.defaultTitle) : title
        var body = ""
        if breakIndex < inline.count {
            let remainder = inline.dropFirst(breakIndex + 1).compactMap { $0 as? any InlineMarkup }
            if !remainder.isEmpty {
                body += render(Paragraph(remainder), sourceLines: sourceLines, autolinks: autolinks)
            }
        }
        body += quote.children.dropFirst().map { render($0, sourceLines: sourceLines, autolinks: autolinks) }.joined()
        return marker.kind.opening + "\n" + marker.kind.title(titleHTML) + "\n" + body + "</div>\n"
    }

    /// Items of a tight list hold their paragraphs' text directly, as CommonMark renders them, so a task's checkbox
    /// stays on its text's line and the items keep no paragraph spacing.
    private static func renderItems(of list: any Markup, sourceLines: [String], autolinks: Bool) -> String {
        let tight = !isLoose(list, sourceLines: sourceLines)
        return list.children.map { child in
            guard let item = child as? ListItem else {
                return render(child, sourceLines: sourceLines, autolinks: autolinks)
            }
            let checkbox =
                item.checkbox.map {
                    "<input type=\"checkbox\" disabled" + ($0 == .checked ? " checked" : "") + "> "
                } ?? ""
            var leadsWithCheckbox = !checkbox.isEmpty
            let body = item.children.map { block -> String in
                guard block is Paragraph else { return render(block, sourceLines: sourceLines, autolinks: autolinks) }
                let text = renderChildren(block, sourceLines: sourceLines, autolinks: autolinks)
                // In a loose list the checkbox goes inside the first paragraph, so it still sits on the text's line.
                let prefix = leadsWithCheckbox ? checkbox : ""
                leadsWithCheckbox = false
                return tight ? prefix + text : "<p>\(prefix)\(text)</p>\n"
            }.joined()
            let attributes = item.checkbox == nil ? "" : " class=\"task-list-item\""
            return "<li\(attributes)>\(leadsWithCheckbox ? checkbox : "")\(body)</li>\n"
        }.joined()
    }

    /// CommonMark calls a list loose when a blank line separates two of its items, or two blocks directly inside one
    /// of them. swift-markdown does not keep that, so it is read from the source lines between the blocks; blank lines
    /// inside a block, such as a code block or a nested list, do not count.
    private static func isLoose(_ list: any Markup, sourceLines: [String]) -> Bool {
        func lastLine(of node: any Markup) -> Int? {
            if node is ListItem || node is UnorderedList || node is OrderedList || node is BlockQuote {
                // An empty item's own range runs over the blank lines after it, so its marker line ends it.
                guard let last = Array(node.children).last else { return node.range?.lowerBound.line }
                return lastLine(of: last)
            }
            return node.range?.upperBound.line
        }
        // Inside block quotes a separating line still carries their markers, so ">" alone counts as blank.
        var quoteDepth = 0
        var ancestor = list.parent
        while let node = ancestor {
            if node is BlockQuote { quoteDepth += 1 }
            ancestor = node.parent
        }
        func isBlank(_ line: String) -> Bool {
            var rest = Substring(line)
            for _ in 0..<quoteDepth {
                let marker = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard marker.first == ">" else { break }
                rest = marker.dropFirst()
                if rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
            }
            return rest.trimmingCharacters(in: .whitespaces).isEmpty
        }
        func blankLine(between earlier: any Markup, and later: any Markup) -> Bool {
            // Lines are 1-based, so the lines strictly between are the indices from `end` to `start - 2`.
            guard let end = lastLine(of: earlier), let start = later.range?.lowerBound.line, start - 1 > end else {
                return false
            }
            return sourceLines[min(end, sourceLines.count)..<min(start - 1, sourceLines.count)].contains(where: isBlank)
        }
        let items = Array(list.children)
        for (earlier, later) in zip(items, items.dropFirst()) where blankLine(between: earlier, and: later) {
            return true
        }
        return items.contains { item in
            let blocks = Array(item.children)
            return zip(blocks, blocks.dropFirst()).contains { blankLine(between: $0, and: $1) }
        }
    }

    private static func renderChildren(_ node: any Markup, sourceLines: [String], autolinks: Bool = true) -> String {
        var insideRawAnchor = false
        return node.children.map { child in
            if let html = child as? InlineHTML {
                if html.rawHTML.range(of: #"^<a(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    insideRawAnchor = true
                } else if html.rawHTML.lowercased().hasPrefix("</a>") {
                    insideRawAnchor = false
                }
            }
            return render(child, sourceLines: sourceLines, autolinks: autolinks && !insideRawAnchor)
        }.joined()
    }

    private static func renderAutolinks(_ text: String) -> String {
        let domain = #"(?:[\p{L}\p{N}_-]+\.)*[\p{L}\p{N}-]+\.[\p{L}\p{N}-]+"#
        let web = #"(?<![^\s*_~(])(?:https?://|www\.)"# + domain + #"[^\s<]*"#
        let email = #"(?:mailto:|xmpp:)?[A-Za-z0-9._+\-]+@[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)+"#
        guard let regex = try? NSRegularExpression(pattern: "(?<web>\(web))|\(email)", options: [.caseInsensitive])
        else {
            return HTML.escape(text)
        }
        var output = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var label = String(text[range])
            let isWeb = match.range(withName: "web").location != NSNotFound
            if isWeb {
                var openingParentheses = 0
                var closingParentheses = 0
                for character in label {
                    if character == "(" { openingParentheses += 1 }
                    if character == ")" { closingParentheses += 1 }
                }
                while let last = label.last {
                    if "?!.,:*_~".contains(last) {
                        label.removeLast()
                    } else if last == ")", closingParentheses > openingParentheses {
                        label.removeLast()
                        closingParentheses -= 1
                    } else {
                        break
                    }
                }
                if let entity = label.range(of: #"&[A-Za-z0-9]+;$"#, options: .regularExpression) {
                    label.removeSubrange(entity)
                }
            } else if label.hasSuffix("-") || label.hasSuffix("_") {
                continue
            }
            let destination: String
            if isWeb && label.lowercased().hasPrefix("www.") {
                destination = "http://" + label
            } else if isWeb || label.lowercased().hasPrefix("mailto:") || label.lowercased().hasPrefix("xmpp:") {
                destination = label
            } else {
                destination = "mailto:" + label
            }
            output += HTML.escape(String(text[cursor..<range.lowerBound]))
            output += "<a href=\"\(HTML.escape(destination))\">\(HTML.escape(label))</a>"
            cursor = text.index(range.lowerBound, offsetBy: label.count)
        }
        return output + HTML.escape(String(text[cursor...]))
    }

    private static func renderTable(_ table: Table, sourceLines: [String]) -> String {
        func cells(_ node: any Markup, tag: String) -> String {
            node.children.enumerated().map { index, cell in
                var attributes = ""
                if index < table.columnAlignments.count, let alignment = table.columnAlignments[index] {
                    attributes += " align=\"\(alignment)\""
                }
                return "<\(tag)\(attributes)>\(renderChildren(cell, sourceLines: sourceLines))</\(tag)>"
            }.joined()
        }
        let head = "<thead><tr>\(cells(table.head, tag: "th"))</tr></thead>"
        let body = table.body.children.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined()
        return "<table>\(head)<tbody>\(body)</tbody></table>\n"
    }
}
