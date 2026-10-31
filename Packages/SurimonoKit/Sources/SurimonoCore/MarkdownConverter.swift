import Foundation
import Markdown

public enum MarkdownConverter {
    public static func convert(_ text: String) -> HTMLFragment {
        convertDocument(text, mapsSource: false).fragment
    }

    public static func convertWithSourceMap(_ text: String) -> MarkdownMappedDocument {
        convertDocument(text, mapsSource: true)
    }

    private static func convertDocument(_ text: String, mapsSource: Bool) -> MarkdownMappedDocument {
        let original = TextDecoding.normalizeNewlines(text).components(separatedBy: "\n")
        var source = mapsSource ? MarkdownSourceLines(original) : .unmapped(original)
        var lines = original
        let mapping = mapsSource ? BlockMapping(original: original) : nil
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
            source = MarkdownSourceLines(lines, origins: Array(source.origins.dropFirst(end + 1)))
        }
        let extracted = MarkdownExtensions.extractFootnotes(source)
        let footnotes = MarkdownExtensions.Footnotes(
            definitions: extracted.definitions.mapValues { $0.lines.joined(separator: "\n") })
        let formulas = MarkdownExtensions.Formulas()
        let (body, document) = renderBody(
            extracted.body, footnotes: footnotes, formulas: formulas, anchorsHeadings: true, mapping: mapping)
        if title == nil { title = firstHeading(in: document, formulas: formulas) }
        let html =
            body + footnoteSection(footnotes, formulas: formulas, definitions: extracted.definitions, mapping: mapping)
        // At the end of the body, so the theme's rules for the first block still find the document's first block.
        let fonts = MathRenderer.fontFaces(for: html)
        return MarkdownMappedDocument(
            fragment: HTMLFragment(body: html + (fonts.isEmpty ? "" : "<style>\n\(fonts)\n</style>\n"), title: title),
            blocks: mapping?.blocks ?? [])
    }

    private final class BlockMapping {
        let original: [String]
        var blocks: [MarkdownBlock] = []
        var occurrences: [String: Int] = [:]

        init(original: [String]) { self.original = original }

        func tag(_ html: String, lines: Set<Int>, kind: String) -> String {
            guard !lines.isEmpty, let end = html.firstIndex(of: ">"), html.first == "<" else { return html }
            let content = lines.sorted().compactMap { original.indices.contains($0 - 1) ? original[$0 - 1] : nil }
                .joined(separator: "\n")
            let digest = String(ContentHash.of(Data((kind + "\n" + content).utf8)).hex.prefix(24))
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            let id = "md-\(digest)-\(occurrence)"
            blocks.append(MarkdownBlock(id: id, lines: lines))
            return String(html[..<end]) + " data-surimono-block=\"\(id)\"" + html[end...]
        }
    }

    /// The source lines the AST was parsed from, the heading anchors still to hand out in document order, and the
    /// formulas whose tokens the text holds.
    private final class Context {
        let sourceLines: [String]
        let origins: [Set<Int>]
        let mapping: BlockMapping?
        let anchors: [MarkdownExtensions.HeadingAnchor]
        let formulas: MarkdownExtensions.Formulas
        var nextAnchor = 0

        init(
            source: MarkdownSourceLines, anchors: [MarkdownExtensions.HeadingAnchor],
            formulas: MarkdownExtensions.Formulas,
            mapping: BlockMapping?
        ) {
            sourceLines = source.lines
            origins = source.origins
            self.mapping = mapping
            self.anchors = anchors
            self.formulas = formulas
        }
    }

    private static func renderBody(
        _ lines: MarkdownSourceLines, footnotes: MarkdownExtensions.Footnotes, formulas: MarkdownExtensions.Formulas,
        anchorsHeadings: Bool, mapping: BlockMapping? = nil
    ) -> (String, Document) {
        let source = MarkdownCallouts.preprocess(
            MarkdownExtensions.rewriteInline(lines, footnotes: footnotes, formulas: formulas))
        let document = Document(parsing: source.lines.joined(separator: "\n"), options: [.disableSmartOpts])
        let context = Context(
            source: source,
            anchors: anchorsHeadings ? MarkdownExtensions.headingAnchors(in: document, formulas: formulas) : [],
            formulas: formulas, mapping: mapping)
        return (render(document, context), document)
    }

    private static func sourceLines(of node: any Markup, _ context: Context) -> Set<Int> {
        guard let range = node.range else { return [] }
        let start = max(0, range.lowerBound.line - 1)
        var end = min(context.origins.count, range.upperBound.line)
        if node is ListItem {
            while end > start, context.sourceLines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        }
        guard start < end else { return [] }
        return context.origins[start..<end].reduce(into: Set<Int>()) { $0.formUnion($1) }
    }

    private static func mapped(_ html: String, node: any Markup, _ context: Context) -> String {
        context.mapping?.tag(html, lines: sourceLines(of: node, context), kind: String(describing: type(of: node)))
            ?? html
    }

    /// The notes in the order the text first refers to them. A note may refer to another note, which then joins the
    /// end of the list. Paper has no way back from a note, so the notes carry no return links.
    private static func footnoteSection(
        _ footnotes: MarkdownExtensions.Footnotes, formulas: MarkdownExtensions.Formulas,
        definitions: [String: MarkdownSourceLines], mapping: BlockMapping?
    ) -> String {
        guard !footnotes.order.isEmpty else { return "" }
        var items = ""
        var index = 0
        while index < footnotes.order.count {
            let definition = footnotes.definitions[footnotes.order[index]] ?? ""
            let (html, _) = renderBody(
                MarkdownSourceLines.unmapped(definition.components(separatedBy: "\n")), footnotes: footnotes,
                formulas: formulas,
                anchorsHeadings: false)
            let item = "<li id=\"fn-\(index + 1)\">\(html)</li>\n"
            let origins =
                definitions[footnotes.order[index]]?.origins.reduce(into: Set<Int>()) { $0.formUnion($1) } ?? []
            items += mapping?.tag(item, lines: origins, kind: "footnote") ?? item
            index += 1
        }
        return "<section class=\"footnotes\">\n<ol>\n\(items)</ol>\n</section>\n"
    }

    private static func firstHeading(in node: any Markup, formulas: MarkdownExtensions.Formulas) -> String? {
        if let heading = node as? Heading, heading.level == 1 {
            return MarkdownExtensions.splitCustomID(MarkdownExtensions.plainText(heading, formulas: formulas)).text
        }
        for child in node.children {
            if let title = firstHeading(in: child, formulas: formulas) { return title }
        }
        return nil
    }

    // Render from the AST because HTMLFormatter does not escape text or attributes.
    private static func render(_ node: any Markup, _ context: Context, autolinks: Bool = true) -> String {
        let html = renderUnmapped(node, context, autolinks: autolinks)
        switch node {
        case is Paragraph, is Heading, is CodeBlock, is BlockQuote, is ThematicBreak, is Table:
            return mapped(html, node: node, context)
        case let raw as HTMLBlock
        where raw.rawHTML.hasPrefix("<div class=\"math-block\"")
            || raw.rawHTML.hasPrefix("<div class=\"callout "):
            return mapped(html, node: node, context)
        default: return html
        }
    }

    private static func renderUnmapped(_ node: any Markup, _ context: Context, autolinks: Bool) -> String {
        func children(allowLinks: Bool? = nil) -> String {
            renderChildren(node, context, autolinks: allowLinks ?? autolinks)
        }
        func wrap(_ tag: String) -> String { "<\(tag)>\(children())</\(tag)>" }
        switch node {
        case let text as Text:
            let html =
                autolinks ? renderAutolinks(text.string) : HTML.escape(MarkdownExtensions.emojified(text.string))
            return context.formulas.restore(html)
        case let code as InlineCode: return "<code>\(HTML.escape(code.code))</code>"
        case let code as CodeBlock where code.language?.lowercased() == "math":
            let formula =
                MathRenderer.html(code.code, display: true) ?? MathRenderer.fallback(code.code, display: true)
            return "<div class=\"math-block\">\(formula)</div>\n"
        case let code as CodeBlock:
            let highlighted = code.language.flatMap { SyntaxHighlighter.highlight(code.code, language: $0) }
            let language =
                code.language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
            return "<pre><code\(language)>\(highlighted ?? HTML.escape(code.code))</code></pre>\n"
        case let heading as Heading:
            var attributes = ""
            if context.nextAnchor < context.anchors.count {
                attributes = " id=\"\(HTML.escape(context.anchors[context.nextAnchor].id))\""
                context.nextAnchor += 1
            }
            let content = MarkdownExtensions.splitCustomID(children()).text
            return "<h\(heading.level)\(attributes)>\(content)</h\(heading.level)>\n"
        case let paragraph as Paragraph:
            if MarkdownExtensions.isTableOfContentsMarker(paragraph) {
                return MarkdownExtensions.tableOfContents(context.anchors)
            }
            return definitionList(paragraph, context, autolinks: autolinks) ?? (wrap("p") + "\n")
        case is Strong: return wrap("strong")
        case is Emphasis: return wrap("em")
        case is Strikethrough: return wrap("del")
        case let quote as BlockQuote:
            return renderCallout(quote, context, autolinks: autolinks) ?? (wrap("blockquote") + "\n")
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
            return
                "<img src=\"\(HTML.escape(image.source ?? ""))\" alt=\"\(HTML.escape(context.formulas.strip(image.plainText)))\"\(title)>"
        case let list as OrderedList:
            return
                "<ol start=\"\(list.startIndex)\">\(renderItems(of: list, context, autolinks: autolinks))</ol>\n"
        case let list as UnorderedList:
            return "<ul>\(renderItems(of: list, context, autolinks: autolinks))</ul>\n"
        case let table as Table: return renderTable(table, context)
        default: return children()
        }
    }

    /// `Term` followed by lines that start with `: ` is a definition list; a later line without the colon starts the
    /// next term.
    private static func definitionList(_ paragraph: Paragraph, _ context: Context, autolinks: Bool) -> String? {
        let lines = MarkdownExtensions.lines(of: paragraph)
        guard lines.count >= 2, MarkdownExtensions.definitionBody(lines[0], sourceLines: context.sourceLines) == nil,
            MarkdownExtensions.definitionBody(lines[1], sourceLines: context.sourceLines) != nil
        else { return nil }
        let items = lines.map { line in
            if let body = MarkdownExtensions.definitionBody(line, sourceLines: context.sourceLines) {
                return "<dd>\(renderChildren(Paragraph(body), context, autolinks: autolinks))</dd>\n"
            }
            return "<dt>\(renderChildren(Paragraph(line), context, autolinks: autolinks))</dt>\n"
        }
        return "<dl>\n" + items.joined() + "</dl>\n"
    }

    /// The looser form: a paragraph of terms, then one or more paragraphs that start with `: `.
    private static func looseDefinitionList(
        _ blocks: [any Markup], at index: Int, _ context: Context, autolinks: Bool
    ) -> (html: String, consumed: Int)? {
        func startsWithDefinition(_ block: any Markup) -> Bool {
            guard let paragraph = block as? Paragraph, let first = MarkdownExtensions.lines(of: paragraph).first else {
                return false
            }
            return MarkdownExtensions.definitionBody(first, sourceLines: context.sourceLines) != nil
        }
        guard index + 1 < blocks.count, let terms = blocks[index] as? Paragraph,
            !MarkdownExtensions.isTableOfContentsMarker(terms),
            MarkdownExtensions.lines(of: terms).allSatisfy({
                MarkdownExtensions.definitionBody($0, sourceLines: context.sourceLines) == nil
            }),
            startsWithDefinition(blocks[index + 1])
        else { return nil }
        var html = "<dl>\n"
        for line in MarkdownExtensions.lines(of: terms) {
            html += "<dt>\(renderChildren(Paragraph(line), context, autolinks: autolinks))</dt>\n"
        }
        var cursor = index + 1
        while cursor < blocks.count, startsWithDefinition(blocks[cursor]), let paragraph = blocks[cursor] as? Paragraph
        {
            // Within one paragraph each `: ` line starts a definition and other lines continue it.
            var definitions: [[any InlineMarkup]] = []
            for line in MarkdownExtensions.lines(of: paragraph) {
                if let body = MarkdownExtensions.definitionBody(line, sourceLines: context.sourceLines) {
                    definitions.append(body)
                } else {
                    definitions[definitions.count - 1] += [SoftBreak()] + line
                }
            }
            for body in definitions {
                html += "<dd>\(renderChildren(Paragraph(body), context, autolinks: autolinks))</dd>\n"
            }
            cursor += 1
        }
        return (html + "</dl>\n", cursor - index)
    }

    private static func renderCallout(_ quote: BlockQuote, _ context: Context, autolinks: Bool) -> String? {
        let sourceLines = context.sourceLines
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
        let title = renderChildren(Paragraph(titleNodes), context, autolinks: autolinks)
        let titleHTML = title.isEmpty ? HTML.escape(marker.kind.defaultTitle) : title
        var body = ""
        if breakIndex < inline.count {
            let remainder = inline.dropFirst(breakIndex + 1).compactMap { $0 as? any InlineMarkup }
            if !remainder.isEmpty {
                let paragraphHTML = render(Paragraph(remainder), context, autolinks: autolinks)
                let origins = Self.sourceLines(of: paragraph, context).subtracting(context.origins[start.line - 1])
                body += context.mapping?.tag(paragraphHTML, lines: origins, kind: "Paragraph") ?? paragraphHTML
            }
        }
        body += quote.children.dropFirst().map { render($0, context, autolinks: autolinks) }.joined()
        return marker.kind.opening + "\n" + marker.kind.title(titleHTML) + "\n" + body + "</div>\n"
    }

    /// Items of a tight list hold their paragraphs' text directly, as CommonMark renders them, so a task's checkbox
    /// stays on its text's line and the items keep no paragraph spacing.
    private static func renderItems(of list: any Markup, _ context: Context, autolinks: Bool) -> String {
        let tight = !isLoose(list, sourceLines: context.sourceLines)
        return list.children.map { child in
            guard let item = child as? ListItem else {
                return render(child, context, autolinks: autolinks)
            }
            let checkbox =
                item.checkbox.map {
                    "<input type=\"checkbox\" disabled" + ($0 == .checked ? " checked" : "") + "> "
                } ?? ""
            var leadsWithCheckbox = !checkbox.isEmpty
            let body = item.children.map { block -> String in
                guard block is Paragraph else { return render(block, context, autolinks: autolinks) }
                let text = renderChildren(block, context, autolinks: autolinks)
                // In a loose list the checkbox goes inside the first paragraph, so it still sits on the text's line.
                let prefix = leadsWithCheckbox ? checkbox : ""
                leadsWithCheckbox = false
                return tight ? prefix + text : "<p>\(prefix)\(text)</p>\n"
            }.joined()
            let attributes = item.checkbox == nil ? "" : " class=\"task-list-item\""
            return mapped("<li\(attributes)>\(leadsWithCheckbox ? checkbox : "")\(body)</li>\n", node: item, context)
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

    private static func renderChildren(_ node: any Markup, _ context: Context, autolinks: Bool = true) -> String {
        let children = Array(node.children)
        var output = ""
        var insideRawAnchor = false
        var index = 0
        while index < children.count {
            if let list = looseDefinitionList(children, at: index, context, autolinks: autolinks) {
                let origins = children[index..<(index + list.consumed)].reduce(into: Set<Int>()) {
                    $0.formUnion(sourceLines(of: $1, context))
                }
                output += context.mapping?.tag(list.html, lines: origins, kind: "definition-list") ?? list.html
                index += list.consumed
                continue
            }
            let child = children[index]
            if let html = child as? InlineHTML {
                if html.rawHTML.range(of: #"^<a(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    insideRawAnchor = true
                } else if html.rawHTML.lowercased().hasPrefix("</a>") {
                    insideRawAnchor = false
                }
            }
            output += render(child, context, autolinks: autolinks && !insideRawAnchor)
            index += 1
        }
        return output
    }

    private static func renderAutolinks(_ text: String) -> String {
        let domain = #"(?:[\p{L}\p{N}_-]+\.)*[\p{L}\p{N}-]+\.[\p{L}\p{N}-]+"#
        let web = #"(?<![^\s*_~(])(?:https?://|www\.)"# + domain + #"[^\s<]*"#
        let email = #"(?:mailto:|xmpp:)?[A-Za-z0-9._+\-]+@[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)+"#
        guard let regex = try? NSRegularExpression(pattern: "(?<web>\(web))|\(email)", options: [.caseInsensitive])
        else {
            return HTML.escape(MarkdownExtensions.emojified(text))
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
            // Emoji shortcodes apply around a URL, never inside it, so the link keeps its destination.
            output += HTML.escape(MarkdownExtensions.emojified(String(text[cursor..<range.lowerBound])))
            output += "<a href=\"\(HTML.escape(destination))\">\(HTML.escape(label))</a>"
            cursor = text.index(range.lowerBound, offsetBy: label.count)
        }
        return output + HTML.escape(MarkdownExtensions.emojified(String(text[cursor...])))
    }

    private static func renderTable(_ table: Table, _ context: Context) -> String {
        func cells(_ node: any Markup, tag: String) -> String {
            node.children.enumerated().map { index, cell in
                var attributes = ""
                if index < table.columnAlignments.count, let alignment = table.columnAlignments[index] {
                    attributes += " align=\"\(alignment)\""
                }
                return "<\(tag)\(attributes)>\(renderChildren(cell, context))</\(tag)>"
            }.joined()
        }
        let head = "<thead><tr>\(cells(table.head, tag: "th"))</tr></thead>"
        let body = table.body.children.map { "<tr>\(cells($0, tag: "td"))</tr>" }.joined()
        return "<table>\(head)<tbody>\(body)</tbody></table>\n"
    }
}
