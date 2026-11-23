import Foundation

public enum OrgConverter {
    /// On a stack of known size, so a document reads the same on every thread.
    /// `defaults` decide what the document's own `#+OPTIONS:` lines leave open.
    public static func convert(_ text: String, defaults: OrgReadingDefaults = .surimono) -> HTMLFragment {
        StackSpace.onLargeStack {
            let (fragment, reachedLimit) = StackSpace.collectingLimit { convertInPlace(text, defaults: defaults) }
            return fragment.notingLimit(reachedLimit)
        }
    }

    private static func convertInPlace(_ text: String, defaults: OrgReadingDefaults) -> HTMLFragment {
        var parser = OrgParser(
            lines: TextDecoding.normalizeNewlines(text).components(separatedBy: "\n"),
            context: OrgContext(defaults: defaults))
        // Discover forward declarations before rendering headings or numbering any references.
        parser.context.discovering = true
        _ = parser.render()
        for key in ["TITLE", "SUBTITLE", "AUTHOR", "DATE"] {
            if let value = parser.context.metadata[key] { _ = OrgInline.render(value, context: parser.context) }
        }
        parser.context.discovering = false
        parser.context.anonymous = 0
        parser.context.reading = parser.context.options.resolved(over: defaults)
        parser.index = 0
        var titleBlock = ""
        for (key, tag) in [("TITLE", "h1"), ("SUBTITLE", "p"), ("AUTHOR", "p"), ("DATE", "p")] {
            if let value = parser.context.metadata[key] {
                titleBlock +=
                    "<\(tag) class=\"org-\(key.lowercased())\">\(OrgInline.render(value, context: parser.context))</\(tag)>"
            }
        }
        if !titleBlock.isEmpty { titleBlock = "<header class=\"org-title-block\">\(titleBlock)</header>\n" }
        let content = parser.render()
        let context = parser.context
        let japanese = context.metadata["LANGUAGE"]?.lowercased().hasPrefix("ja") == true
        var tables: [OrgOutline.Request: (html: String, count: Int)] = [:]
        var budget = OrgOutline.entryBudget
        /// The table for a request, built once however often the document asks for it, while the budget lasts.
        func contents(_ request: OrgOutline.Request) -> String {
            let table =
                tables[request]
                ?? context.outline.contents(
                    request, headlineLevels: context.reading.headlineLevels,
                    title: japanese ? "目次" : "Table of Contents")
            tables[request] = table
            guard table.count <= budget else { return "" }
            budget -= table.count
            return table.html
        }
        let depth = context.reading.tableOfContents
        var pieces = [titleBlock]
        if depth != .off { pieces.append(contents(OrgOutline.Request(depth: depth == .all ? nil : depth.limit))) }
        // Each mark is found once, in one walk over the text, however many tables the document asks for.
        let marked = content.components(separatedBy: "<!--\(context.contentsToken)-")
        pieces.append(marked[0])
        for piece in marked.dropFirst() {
            guard let end = piece.range(of: "-->\n"), let position = Int(piece[..<end.lowerBound]),
                context.outline.requests.indices.contains(position)
            else { continue }
            pieces.append(contents(context.outline.requests[position]))
            pieces.append(String(piece[end.upperBound...]))
        }
        pieces.append(parser.footnotes())
        let html = pieces.joined()
        // At the end of the body, so the theme's rules for the first block still find the document's first block.
        let fonts = MathRenderer.fontFaces(for: html)
        return HTMLFragment(
            body: html + (fonts.isEmpty ? "" : "<style>\n\(fonts)\n</style>\n"),
            title: parser.context.metadata["TITLE"], language: parser.context.metadata["LANGUAGE"],
            decidesHeadingNumbers: context.options.sectionNumbers != nil || context.reading.sectionNumbers != .off)
    }
}

struct OrgParser {
    let lines: [String]
    let depth: Int
    private let regionEnds: [Int: Int]
    var index = 0
    let context: OrgContext
    private var openList: (indent: Int, tag: String)?
    /// For each environment name, the lines last searched without finding a closing line; an opener among them
    /// need not search again.
    private var unclosedEnvironments: [String: Range<Int>] = [:]

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

    private struct Child {
        let lines: [String]
        var isListItem = false
        // Discovery renders note definitions for their side effects only.
        var closing: String?
    }

    mutating func render() -> String {
        var parents: [(parser: OrgParser, isListItem: Bool, savedOutput: String?, closing: String?)] = []
        var isListItem = false
        var output = ""
        while true {
            if let child = renderSegment(isListItem: isListItem, into: &output) {
                parents.append((self, isListItem, child.closing == nil ? output : nil, child.closing))
                self = OrgParser(lines: child.lines, depth: depth + 1, context: context)
                isListItem = child.isListItem
                if child.closing == nil { output = "" }
            } else if let parent = parents.popLast() {
                self = parent.parser
                isListItem = parent.isListItem
                if let saved = parent.savedOutput { output = saved }
                if let closing = parent.closing { output += closing }
            } else {
                return output
            }
        }
    }

    // Yield only at block boundaries, after flushing the paragraph. The parent's next unread line and
    // pending list survive on the heap; a nested block inherits the same discovery and numbering context.
    private mutating func renderSegment(isListItem: Bool, into output: inout String) -> Child? {
        guard depth < 32 else {
            StackSpace.noteLimitReached()
            output += "<p>\(HTML.escape(lines.joined(separator: "\n")))</p>\n"
            return nil
        }

        var paragraph: [String] = []
        var caption: String?
        func flush() {
            if !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                if !isListItem, let formula = OrgMath.displayBlock(text, context: context) {
                    output += formula
                    caption = nil
                    paragraph = []
                    return
                }
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
        while index < lines.count || openList != nil {
            if let list = openList {
                if index < lines.count, let item = listItem(lines[index]), item.indent == list.indent,
                    item.tag == list.tag
                {
                    return listChild(item, into: &output)
                }
                output += "</\(list.tag)>\n"
                openList = nil
                continue
            }
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
                    return Child(lines: definition, closing: nil)
                }
                caption = nil
            } else if let region = delimitedRegion(at: index) {
                if let end = endOfRegion(region, after: index) {
                    flush()
                    caption = nil
                    let start = index + 1
                    index = end + 1
                    if case .block(let kind, let arguments) = region {
                        let content = Array(lines[start..<end])
                        if region.isLiteral {
                            output += literalBlock(kind: kind, arguments: arguments, content: content)
                        } else {
                            let wrapper = blockWrapper(kind)
                            output += wrapper.opening
                            return Child(lines: content, closing: wrapper.closing)
                        }
                    }
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
            } else if let name = OrgMath.environmentName(trimmed), let end = endOfEnvironment(name, from: index) {
                flush()
                caption = nil
                let source = lines[index...end].joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                let body = String(source.dropFirst("\\begin{\(name)}".count).dropLast("\\end{\(name)}".count))
                output += OrgMath.environment(name, body: body, context: context)
                index = end + 1
            } else if let heading = orgCaptures(#"^(\*+)\s+(.+)$"#, line) {
                flush()
                caption = nil
                let level = min(6, heading[0].count + (context.metadata["TITLE"] == nil ? 0 : 1))
                let done = context.done.contains(
                    heading[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
                var attribute = done ? " class=\"org-done-heading\"" : ""
                let parts = renderHeading(heading[1])
                var number = ""
                // Only the document's own outline is numbered and listed; a starred line inside a block or a
                // list item is not part of it.
                if depth == 0, context.discovering {
                    context.outline.shallowest = min(context.outline.shallowest ?? Int.max, heading[0].count)
                    // Known before any id is made, so a made id never takes one the document wrote further down.
                    if let custom = customID(after: index) { context.outline.reserve(custom) }
                } else if depth == 0 {
                    let numbers = context.reading.sectionNumbers.limit > 0
                    let anchors = context.anchorsHeadings
                    let properties = headingProperties(after: index)
                    let relative = heading[0].count - (context.outline.shallowest ?? 1) + 1
                    var listed = true
                    // A document without numbers and without a table of contents keeps no outline at all.
                    if numbers || anchors {
                        let unnumbered = context.outline.unnumberedValue(level: relative, properties: properties)
                        listed = unnumbered != "notoc"
                        if numbers, unnumbered == nil {
                            let next = context.outline.nextNumber(level: relative)
                            if relative <= context.reading.sectionNumbers.limit {
                                number = "<span class=\"section-number-\(level)\">\(next)</span> "
                            }
                        }
                    }
                    // The id the document wrote is a link target with or without a table of contents.
                    let custom = customID(after: index)
                    if anchors || custom != nil {
                        let id =
                            custom
                            ?? context.outline.id(
                                for: HTML.unescape(Self.withoutTags(Self.withoutNotes(parts.title))))
                        attribute = " id=\"\(HTML.escape(id))\"" + attribute
                        if anchors {
                            context.outline.entries.append(
                                OrgOutline.Entry(
                                    level: relative, id: id,
                                    html: Self.withoutLinks(
                                        Self.withoutNotes(Self.withoutTags(number) + parts.html)),
                                    listed: listed))
                        }
                    }
                }
                output += "<h\(level)\(attribute)>\(number)\(parts.html)</h\(level)>\n"
                index += 1
            } else if let directive = orgCaptures(#"^#\+([A-Za-z_]+):\s*(.*)$"#, trimmed) {
                flush()
                let key = directive[0].uppercased()
                if depth == 0, context.discovering { context.directive(key, value: directive[1]) }
                if key == "TOC", depth == 0, !context.discovering, let request = contentsRequest(directive[1]) {
                    output += "<!--\(context.contentsToken)-\(context.outline.requests.count)-->\n"
                    context.outline.requests.append(request)
                }
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
                output += "<pre>\(HTML.escape(fixed.joined(separator: "\n")))</pre>\n"
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
                let tag = item.tag
                let start = tag == "ol" ? " start=\"\(item.number ?? "1")\"" : ""
                output += "<\(tag)\(start)>"
                openList = (item.indent, tag)
                return listChild(item, into: &output)
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flush()
        return nil
    }

    private func literalBlock(kind: String, arguments: String, content: [String]) -> String {
        let text = content.joined(separator: "\n")
        switch kind {
        case "SRC":
            let language = arguments.split(whereSeparator: \.isWhitespace).first.map(String.init)
            if language?.lowercased() == "mermaid" { return MermaidBlock.html(text) }
            if let format = DiagramConverter.format(language: language) {
                return DiagramConverter.block(text, format: format)
            }
            let highlighted = language.flatMap { SyntaxHighlighter.highlight(text, language: $0) }
            let attribute =
                language.map { " class=\"language-\(HTML.escape($0))\(highlighted == nil ? "" : " hl")\"" } ?? ""
            return "<pre><code\(attribute)>\(highlighted ?? HTML.escape(text))</code></pre>\n"
        case "COMMENT", "EXPORT": return ""
        // A bare `pre`, as `CodeBlockMarkup` expects of a code block: the code options then reach it too.
        case "EXAMPLE": return "<pre>\(HTML.escape(text))</pre>\n"
        case "VERSE": return "<div class=\"org-verse\">\(inline(text))</div>\n"
        default: return ""
        }
    }

    private func blockWrapper(_ kind: String) -> (opening: String, closing: String) {
        switch kind {
        case "QUOTE": return ("<blockquote>", "</blockquote>\n")
        case "CENTER": return ("<div class=\"org-center\">", "</div>\n")
        default:
            let name = String(
                kind.lowercased().utf8.filter {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
                }.map { Character(UnicodeScalar($0)) })
            let callout = MarkdownCallouts.Kind(name: name)
            if callout.canonicalName != nil {
                let title =
                    name == "message" ? "" : callout.title(HTML.escape(callout.defaultTitle)) + "\n"
                return (callout.opening + "\n" + title, "</div>\n")
            }
            return ("<div class=\"org-block org-block-\(HTML.escape(name))\">", "</div>\n")
        }
    }

    /// The table a `#+TOC:` line asks for at this point. Lists of tables and listings are not read.
    private func contentsRequest(_ value: String) -> OrgOutline.Request? {
        guard let keyword = OrgOutline.keyword(value) else { return nil }
        let entries = context.outline.entries
        guard keyword.local, let heading = entries.last else { return OrgOutline.Request(depth: keyword.depth) }
        return OrgOutline.Request(depth: keyword.depth, after: entries.count, level: heading.level)
    }

    private func customID(after position: Int) -> String? {
        guard let id = headingProperties(after: position)["CUSTOM_ID"], !id.isEmpty else { return nil }
        return id
    }

    /// The property drawer of the headline at `position`, which may follow one planning line.
    private func headingProperties(after position: Int) -> [String: String] {
        var next = position + 1
        if next < lines.count, OrgInline.planning(lines[next].trimmingCharacters(in: .whitespaces)) != nil {
            next += 1
        }
        guard next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:",
            let end = regionEnds[next]
        else { return [:] }
        var properties: [String: String] = [:]
        for line in lines[(next + 1)..<end] {
            if let property = orgCaptures(#"^\s*:([^\s:]+):\s*(.*?)\s*$"#, line) {
                properties[property[0].uppercased()] = property[1]
            }
        }
        return properties
    }

    private static func withoutNotes(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"<sup class="footnote-ref">.*?</sup>"#, with: "", options: .regularExpression)
    }

    private static func withoutLinks(_ html: String) -> String {
        html.replacingOccurrences(of: #"</?a(?:\s[^>]*)?>"#, with: "", options: .regularExpression)
    }

    private static func withoutTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }

    private func renderHeading(_ source: String) -> (html: String, title: String) {
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
        let title = inline(text, cookies: .all)
        return (prefix + title + tags, title)
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

    private mutating func listChild(_ item: ListItem, into output: inout String) -> Child {
        let definition = item.definition
        let term = definition.map { inline($0[0]) }
        let firstLine = definition?[1] ?? item.content
        index += 1
        let content = [firstLine] + collectListItemContinuation(indent: item.indent)
        if let term {
            output += "<dt>\(term)</dt><dd>"
            return Child(lines: content, closing: "</dd>")
        }
        let task = orgCaptures(#"^\[([ Xx-])\]\s*([\s\S]*)$"#, firstLine) != nil
        output += task ? "<li class=\"task-list-item\">" : "<li>"
        return Child(lines: content, isListItem: true, closing: "</li>")
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

    /// The line that closes a math environment opened at `start`. TeX allows no blank line inside a display, and
    /// a headline ends everything, so an environment left open stays text instead of swallowing the document.
    private mutating func endOfEnvironment(_ name: String, from start: Int) -> Int? {
        if unclosedEnvironments[name]?.contains(start) == true { return nil }
        let closing = "\\end{\(name)}"
        for position in start..<lines.count {
            let line = lines[position].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || position > start && orgCaptures(#"^\*+\s"#, lines[position]) != nil {
                unclosedEnvironments[name] = start..<position
                return nil
            }
            if line.hasSuffix(closing) { return position }
        }
        unclosedEnvironments[name] = start..<lines.count
        return nil
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
