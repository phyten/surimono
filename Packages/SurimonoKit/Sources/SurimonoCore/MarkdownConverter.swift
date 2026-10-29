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
        let document = Document(parsing: MarkdownCallouts.preprocess(lines), options: [.disableSmartOpts])
        if title == nil { title = firstHeading(in: document) }
        return HTMLFragment(body: render(document), title: title)
    }

    private static func firstHeading(in node: any Markup) -> String? {
        if let heading = node as? Heading, heading.level == 1 { return heading.plainText }
        for child in node.children {
            if let title = firstHeading(in: child) { return title }
        }
        return nil
    }

    // Render from the AST because HTMLFormatter does not escape text or attributes.
    private static func render(_ node: any Markup, autolinks: Bool = true) -> String {
        func children(allowLinks: Bool? = nil) -> String {
            renderChildren(node, autolinks: allowLinks ?? autolinks)
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
            return renderCallout(quote, autolinks: autolinks) ?? (wrap("blockquote") + "\n")
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
        case let item as ListItem:
            let checkbox =
                item.checkbox.map {
                    "<input type=\"checkbox\" disabled" + ($0 == .checked ? " checked" : "") + "> "
                } ?? ""
            return "<li>\(checkbox)\(children())</li>\n"
        case let list as OrderedList: return "<ol start=\"\(list.startIndex)\">\(children())</ol>\n"
        case is UnorderedList: return wrap("ul") + "\n"
        case let table as Table: return renderTable(table)
        default: return children()
        }
    }

    private static func renderCallout(_ quote: BlockQuote, autolinks: Bool) -> String? {
        guard let paragraph = quote.child(at: 0) as? Paragraph else { return nil }
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
        let title = renderChildren(Paragraph(titleNodes), autolinks: autolinks)
        let titleHTML = title.isEmpty ? HTML.escape(marker.kind.defaultTitle) : title
        var body = ""
        if breakIndex < inline.count {
            let remainder = inline.dropFirst(breakIndex + 1).compactMap { $0 as? any InlineMarkup }
            if !remainder.isEmpty { body += render(Paragraph(remainder), autolinks: autolinks) }
        }
        body += quote.children.dropFirst().map { render($0, autolinks: autolinks) }.joined()
        return marker.kind.opening + "\n" + marker.kind.title(titleHTML) + "\n" + body + "</div>\n"
    }

    private static func renderChildren(_ node: any Markup, autolinks: Bool = true) -> String {
        var insideRawAnchor = false
        return node.children.map { child in
            if let html = child as? InlineHTML {
                if html.rawHTML.range(of: #"^<a(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    insideRawAnchor = true
                } else if html.rawHTML.lowercased().hasPrefix("</a>") {
                    insideRawAnchor = false
                }
            }
            return render(child, autolinks: autolinks && !insideRawAnchor)
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

    private static func renderTable(_ table: Table) -> String {
        func cells(_ node: any Markup, tag: String) -> String {
            node.children.enumerated().map { index, cell in
                var attributes = ""
                if index < table.columnAlignments.count, let alignment = table.columnAlignments[index] {
                    attributes += " align=\"\(alignment)\""
                }
                return "<\(tag)\(attributes)>\(renderChildren(cell))</\(tag)>"
            }.joined()
        }
        let head = "<thead><tr>\(cells(table.head, tag: "th"))</tr></thead>"
        let body = table.body.children.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined()
        return "<table>\(head)<tbody>\(body)</tbody></table>\n"
    }
}
