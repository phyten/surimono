import Foundation

public enum OrgConverter {
    package static let contentsLimitIssue = "Table of contents size limit reached"

    /// On a stack of known size, so a document reads the same on every thread.
    /// `defaults` decide what the document's own `#+OPTIONS:` lines leave open.
    public static func convert(_ text: String, defaults: OrgReadingDefaults) -> HTMLFragment {
        convert(text, settings: OrgReadingSettings(defaults: defaults))
    }

    public static func convert(
        _ text: String, settings: OrgReadingSettings = .init(), fileName: String? = nil,
        includesLeadContents: Bool = true, proposedLeadDepth: Int? = nil
    ) -> HTMLFragment {
        StackSpace.onLargeStack {
            let (fragment, reachedLimit) = StackSpace.collectingLimit {
                var fragment = convertInPlace(
                    text, settings: settings, fileName: fileName, includesLeadContents: includesLeadContents)
                // A legacy front page need not have heading anchors. Read its proposed replacement separately
                // so the comparison cannot change the legacy body or consume its in-text expansion budget.
                if let proposedLeadDepth, let file = fragment.orgInstructions,
                    settings.resolve(.tableOfContents, file: file).value == .off,
                    settings.resolve(.tableOfContents, file: file).source == nil, !fragment.body.contains("<nav")
                {
                    var proposed = settings
                    proposed.set(.levels(proposedLeadDepth), for: .tableOfContents, file: file)
                    fragment.proposedLeadContents =
                        convertInPlace(
                            text, settings: proposed, fileName: fileName, includesLeadContents: false
                        ).proposedLeadContents
                }
                return fragment
            }
            return fragment.notingLimit(reachedLimit)
        }
    }

    private static func convertInPlace(
        _ text: String, settings: OrgReadingSettings, fileName: String?, includesLeadContents: Bool
    ) -> HTMLFragment {
        var parser = OrgParser(
            lines: TextDecoding.normalizeNewlines(text).components(separatedBy: "\n"),
            context: OrgContext(defaults: settings.defaults, fileName: fileName))
        // Discover forward declarations before rendering headings or numbering any references.
        parser.context.commentEnds = parser.commentRanges()
        parser.context.discovering = true
        _ = parser.render()
        if PreviewConversion.expired { return HTMLFragment(body: "") }
        let context = parser.context
        context.reading = context.options.resolved(over: settings)
        context.omissions = context.subtrees.omissions(context: context, lineCount: parser.lines.count)
        // Priorities may follow a keyword declared later, even in a subtree omitted from the final pass.
        if !context.options.file.hasTaskOrDateElements {
            context.options.file.hasTaskOrDateElements = context.subtrees.headings.contains {
                let title = $0.headline.title
                let word = title.prefix { !$0.isWhitespace }
                if OrgHeadline.isPriority(word) { return true }
                guard context.taskKeywords.contains(String(word)) else { return false }
                let rest = title[word.endIndex...].drop(while: \.isWhitespace)
                return OrgHeadline.isPriority(rest.prefix { !$0.isWhitespace })
            }
        }
        if !context.omissions.isEmpty {
            // Rediscover the visible outline. Named footnotes remain available across subtree boundaries.
            context.repeatingDiscovery = true
            context.propertiesByHeading.removeAll()
            context.outline = OrgOutline()
            context.options.file.clearOutlineNotes()
            context.hasContentsKeyword = false
            context.anonymous = 0
            parser.index = 0
            _ = parser.render()
        }
        var fields: [(String, String)] = []
        if context.reading.title { fields += [("TITLE", "h1"), ("SUBTITLE", "p")] }
        if context.reading.author { fields.append(("AUTHOR", "p")) }
        if context.reading.date { fields.append(("DATE", "p")) }
        for (key, _) in fields {
            if let value = context.metadata[key] { _ = OrgInline.render(value, context: context) }
        }
        // A timestamp in suppressed front matter is still in the manuscript. Keep its inline
        // discovery separate so hidden fields cannot register footnotes in the printed body.
        if !context.options.file.hasTaskOrDateElements {
            context.options.file.hasTaskOrDateElements = context.metadata.contains { key, value in
                guard key != "LANGUAGE", !fields.contains(where: { $0.0 == key }),
                    value.contains("<") || value.contains("[")
                else { return false }
                let discovery = OrgContext()
                discovery.discovering = true
                _ = OrgInline.render(value, context: discovery)
                return discovery.options.file.hasTaskOrDateElements
            }
        }
        context.discovering = false
        context.anonymous = 0
        parser.index = 0
        var titleBlock = ""
        for (key, tag) in fields {
            if let value = parser.context.metadata[key] {
                titleBlock +=
                    "<\(tag) class=\"org-\(key.lowercased())\">\(OrgInline.render(value, context: parser.context))</\(tag)>"
            }
        }
        if !titleBlock.isEmpty { titleBlock = "<header class=\"org-title-block\">\(titleBlock)</header>\n" }
        let content = parser.render()
        let japanese = context.metadata["LANGUAGE"]?.lowercased().hasPrefix("ja") == true
        var contents = OrgContents(
            entries: context.outline.entries, headlineLevels: context.reading.headlineLevels,
            title: japanese ? "目次" : "Table of Contents")
        let depth = context.reading.tableOfContents
        var pieces = [titleBlock]
        var proposed: HTMLFragment.ProposedLead?
        // A separate contents page does not consume the expansion budget of in-text tables.
        if includesLeadContents, depth != .off {
            pieces.append(
                ReaderContentsKind.lead.mark(
                    contents.table(OrgOutline.Request(depth: depth == .all ? nil : depth.limit))))
        }
        if !includesLeadContents && depth != .off {
            var separate = contents
            proposed = .init(
                depth: depth.limit, html: separate.table(OrgOutline.Request(depth: depth == .all ? nil : depth.limit)))
        }
        // Each mark is found once, in one walk over the text, however many tables the document asks for.
        let marked = content.components(separatedBy: "<!--\(context.contentsToken)-")
        pieces.append(marked[0])
        for piece in marked.dropFirst() {
            guard let end = piece.range(of: "-->\n"), let position = Int(piece[..<end.lowerBound]),
                context.outline.requests.indices.contains(position)
            else { continue }
            pieces.append(contents.table(context.outline.requests[position]))
            pieces.append(String(piece[end.upperBound...]))
        }
        pieces.append(parser.footnotes())
        let html = pieces.joined()
        // At the end of the body, so the theme's rules for the first block still find the document's first block.
        let fonts = MathRenderer.fontFaces(for: html)
        var fragment = HTMLFragment(
            body: html + (fonts.isEmpty ? "" : "<style>\n\(fonts)\n</style>\n"),
            title: parser.context.metadata["TITLE"], language: parser.context.metadata["LANGUAGE"],
            readingIssues: contents.omitted ? [OrgConverter.contentsLimitIssue] : [],
            decidesHeadingNumbers: true)
        fragment.proposedLeadContents = proposed
        fragment.orgInstructions = context.options.file
        return fragment.recordingContents()
    }
}

struct OrgParser {
    let lines: [String]
    let depth: Int
    private let sourceOffset: Int
    private let headlines: [Int: OrgHeadline]
    private let regionEnds: [Int: Int]
    var index = 0
    let context: OrgContext
    private var deepHeadings: [(level: Int, tag: String)] = []
    private var planningLine: Int?
    private var openList: (indent: Int, tag: String)?
    /// For each environment name, the lines last searched without finding a closing line; an opener among them
    /// need not search again.
    private var unclosedEnvironments: [String: Range<Int>] = [:]

    init(lines: [String], depth: Int = 0, sourceOffset: Int = 0, context: OrgContext = OrgContext()) {
        self.lines = lines
        self.depth = depth
        self.sourceOffset = sourceOffset
        self.context = context
        // Pair blocks once, respecting literal regions and same-name nesting.
        var outline: [Int: OrgHeadline] = [:]
        var ends: [Int: Int] = [:]
        var stack: [(start: Int, region: DelimitedRegion)] = []
        for (index, line) in lines.enumerated() {
            // A physical headline starts a section even when a preceding block has no closing marker.
            if depth == 0, let headline = OrgHeadline(line) {
                outline[index] = headline
                stack.removeAll(keepingCapacity: true)
                continue
            }
            let marker = line.trimmingCharacters(in: .whitespaces).uppercased()
            if let last = stack.last, marker == last.region.endMarker {
                ends[last.start] = index
                stack.removeLast()
            } else if stack.last?.region.isLiteral != true, let region = Self.region(line) {
                stack.append((index, region))
            }
        }
        headlines = outline
        regionEnds = ends
    }

    /// Resolve commented subtrees before reading any export settings, including forward workflow declarations.
    fileprivate mutating func commentRanges() -> [Int: Int] {
        guard headlines.values.contains(where: { $0.title.contains("COMMENT") }) else { return [:] }
        var outline = OrgCommentOutline()
        defer { index = 0 }
        while index < lines.count {
            let line = lines[index]
            if let end = regionEnds[index] {
                index = end + 1
            } else if let item = listItem(line) {
                index += 1
                _ = collectListItemContinuation(indent: item.indent)
            } else {
                if let heading = headlines[index] {
                    outline.heading(line: index, headline: heading)
                } else if let declaration = orgCaptures(#"^\s*#\+(?:TODO|SEQ_TODO|TYP_TODO):\s*(.*)$"#, line) {
                    outline.workflow(declaration[0])
                }
                index += 1
            }
        }
        return outline.ranges(end: lines.count)
    }

    private struct Child {
        let lines: [String]
        /// Child text may be de-indented, but its lines are contiguous in the parent.
        let startInParent: Int
        var isListItem = false
        // Discovery renders note definitions for their side effects only.
        var closing: String?
    }

    mutating func render() -> String {
        let manuscript = lines
        var parents: [(parser: OrgParser, isListItem: Bool, savedOutput: String?, closing: String?)] = []
        var isListItem = false
        var output = ""
        while true {
            if let child = renderSegment(isListItem: isListItem, manuscript: manuscript, into: &output) {
                parents.append((self, isListItem, child.closing == nil ? output : nil, child.closing))
                self = OrgParser(
                    lines: child.lines, depth: depth + 1, sourceOffset: sourceOffset + child.startInParent,
                    context: context)
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
    private mutating func renderSegment(isListItem: Bool, manuscript: [String], into output: inout String) -> Child? {
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
                if context.reading.timestamps != .all,
                    let filtered = OrgInline.filterIsolatedTimestamps(text, mode: context.reading.timestamps)
                {
                    context.options.file.hasTaskOrDateElements = true
                    if !filtered.isEmpty { output += "<p>\(inline(filtered))</p>\n" }
                    paragraph = []
                    caption = nil
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
            if PreviewConversion.expired { return nil }
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
            if depth == 0, let end = context.omissions[index] ?? context.commentEnds[index] {
                flush()
                caption = nil
                index = end
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
                let start = index
                var definition = [note[1]]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                    orgCaptures(#"^\[fn:([^]:\s]+)\]\s+(.*)$"#, lines[index]) == nil,
                    headlines[index] == nil
                {
                    definition.append(lines[index])
                    index += 1
                }
                if context.discovering {
                    context.definitions[note[0]] = definition.joined(separator: "\n")
                    return Child(lines: definition, startInParent: start, closing: nil)
                }
                caption = nil
            } else if let region = delimitedRegion(at: index) {
                if let end = endOfRegion(region, after: index) {
                    flush()
                    caption = nil
                    let start = index + 1
                    index = end + 1
                    if case .drawer = region {
                        let name = String(trimmed.dropFirst().dropLast())
                        if name.uppercased() == "PROPERTIES" {
                            output += propertyDrawer(lines[start..<end])
                        } else if context.discovering || context.drawerNames.includes(name) {
                            return Child(lines: Array(lines[start..<end]), startInParent: start, closing: "")
                        }
                    } else if case .block(let kind, let arguments) = region {
                        let content = Array(lines[start..<end])
                        if region.isLiteral {
                            output += literalBlock(kind: kind, arguments: arguments, content: content)
                        } else {
                            let wrapper = blockWrapper(kind)
                            output += wrapper.opening
                            return Child(lines: content, startInParent: start, closing: wrapper.closing)
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
                switch context.reading.math {
                case .render: output += OrgMath.environment(name, body: body, context: context)
                case .verbatim: output += "<pre>\(HTML.escape(source))</pre>\n"
                case .off: break
                }
                index = end + 1
            } else if let heading = headlines[index] {
                flush()
                caption = nil
                planningLine = index + 1
                let level = min(
                    6, heading.level + (context.metadata["TITLE"] == nil || !context.reading.title ? 0 : 1))
                let done =
                    context.done.contains(heading.keyword)
                    && (context.reading.todo || context.taskKeywords.contains(heading.keyword))
                var attribute = done ? " class=\"org-done-heading\"" : ""
                let parts = renderHeading(heading)
                var number = ""
                var listTag = "ul"
                let relative = heading.level - (context.outline.shallowest ?? 1) + 1
                let low = !context.discovering && relative > context.reading.headlineLevels
                if context.discovering {
                    if !context.repeatingDiscovery {
                        context.subtrees.headings.append((line: index, headline: heading))
                    }
                    context.outline.shallowest = min(context.outline.shallowest ?? Int.max, heading.level)
                    // Known before any id is made, so a made id never takes one the document wrote further down.
                    let properties = headingProperties(after: index)
                    if !properties.isEmpty { context.propertiesByHeading[index] = properties }
                    if let custom = properties["CUSTOM_ID"], !custom.isEmpty { context.outline.reserve(custom) }
                } else {
                    let anchors = context.anchorsHeadings
                    let properties = context.propertiesByHeading[index] ?? [:]
                    let unnumbered = context.outline.unnumberedValue(level: relative, properties: properties)
                    let listed = unnumbered != "notoc"
                    if !listed { context.options.file.excludedHeadingCount += 1 }
                    let numbered = relative <= context.reading.sectionNumbers.limit && unnumbered == nil
                    listTag = numbered ? "ol" : "ul"
                    if numbered && !low {
                        let next = context.outline.numbers.next(level: relative)
                        number = "<span class=\"section-number-\(level)\">\(next)</span> "
                    }
                    // The id the document wrote is a link target with or without a table of contents.
                    let custom = properties["CUSTOM_ID"].flatMap { $0.isEmpty ? nil : context.outline.customID($0) }
                    if anchors || custom != nil {
                        let id =
                            custom
                            ?? context.outline.id(
                                for: HTML.unescape(Self.withoutTags(Self.withoutNotes(parts.title))))
                        let escapedID = HTML.escape(id)
                        attribute = " id=\"\(escapedID)\"" + attribute
                        if anchors {
                            context.outline.entries.append(
                                OrgOutline.Entry(
                                    level: relative, escapedID: escapedID,
                                    html: Self.withoutLinks(
                                        Self.withoutNotes(Self.withoutTags(number) + parts.contents)),
                                    listed: listed))
                        }
                    }
                }
                while let last = deepHeadings.last,
                    !low || last.level > relative || (last.level == relative && last.tag != listTag)
                {
                    output += "</li></\(last.tag)>\n"
                    deepHeadings.removeLast()
                }
                if low {
                    if deepHeadings.last?.level == relative {
                        output += "</li>\n"
                    } else {
                        output += "<\(listTag)>"
                        deepHeadings.append((relative, listTag))
                    }
                    output += "<li\(attribute)>\(parts.html)\n"
                } else {
                    output += "<h\(level)\(attribute)>\(number)\(parts.html)</h\(level)>\n"
                }
                index += 1
            } else if let directive = orgCaptures(#"^#\+([A-Za-z_]+):\s*(.*)$"#, trimmed) {
                flush()
                let key = directive[0].uppercased()
                if context.discovering, !context.repeatingDiscovery, key == "SETUPFILE" || key == "INCLUDE" {
                    let original = sourceOffset + index
                    // A list marker or footnote label can precede keyword-like text on the same physical line.
                    if manuscript[original].drop(while: \.isWhitespace).hasPrefix("#+") {
                        context.options.file.noteExternalSettings(
                            lines: manuscript, index: original, fileName: context.fileName)
                    }
                }
                if depth == 0, context.discovering {
                    context.directive(key, value: directive[1], lineNumber: index + 1, line: trimmed, lines: lines)
                }
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
            } else if trimmed.hasPrefix("#+") && trimmed.prefix(6).uppercased() == "#+END_" {
                // A closing marker reached on its own belongs to the paragraph after an interrupted block.
                paragraph.append(line)
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
            } else if Self.isClock(trimmed) {
                context.options.file.hasTaskOrDateElements = true
                if context.reading.clocks { paragraph.append(line) }
                index += 1
            } else if index == planningLine, let planning = OrgInline.planning(trimmed) {
                context.options.file.hasTaskOrDateElements = true
                flush()
                caption = nil
                if context.reading.planning { output += planning }
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
                if context.reading.fixedWidth { output += "<pre>\(HTML.escape(fixed.joined(separator: "\n")))</pre>\n" }
            } else if trimmed.hasPrefix("|") {
                flush()
                guard context.discovering || context.reading.tables else {
                    while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        index += 1
                    }
                    caption = nil
                    continue
                }
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
        while let last = deepHeadings.popLast() { output += "</li></\(last.tag)>\n" }
        return nil
    }

    private static func isClock(_ line: String) -> Bool {
        guard line.prefix(6).uppercased() == "CLOCK:" else { return false }
        let stamp = OrgInline.inactiveTimestampPattern
        let duration = #"=>[ \t]+[0-9]+:[0-9]{2}"#
        let rangeEnd = #"--\#(stamp)(?:[ \t]+\#(duration))?"#
        let pattern = #"^CLOCK:[ \t]+(?:\#(stamp)(?:\#(rangeEnd))?|\#(duration))$"#
        return orgCaptures(pattern, line) != nil
    }

    private func propertyDrawer(_ content: ArraySlice<String>) -> String {
        guard !context.discovering, context.reading.properties != .off else { return "" }
        let visible = content.filter { line in
            guard let property = orgCaptures(#"^\s*:([^\s:]+):"#, line) else { return false }
            return context.propertyNames.includes(property[0])
        }
        guard !visible.isEmpty else { return "" }
        return "<pre class=\"org-drawer\">\(HTML.escape(visible.joined(separator: "\n")))</pre>\n"
    }

    private func literalBlock(kind: String, arguments: String, content: [String]) -> String {
        switch kind {
        case "SRC":
            let text = content.map(Self.unquoteLiteralLine).joined(separator: "\n")
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
        case "EXAMPLE":
            return "<pre>\(HTML.escape(content.map(Self.unquoteLiteralLine).joined(separator: "\n")))</pre>\n"
        case "VERSE": return "<div class=\"org-verse\">\(inline(content.joined(separator: "\n")))</div>\n"
        default: return ""
        }
    }

    /// Strip exactly one quoting comma before stars and keywords, preserving indentation and literal commas.
    private static func unquoteLiteralLine(_ line: String) -> String {
        let content = line.drop { $0 == " " || $0 == "\t" }
        guard content.first == "," else { return line }
        let rest = content.drop { $0 == "," }
        guard rest.first == "*" || rest.hasPrefix("#+") else { return line }
        return String(line[..<content.startIndex]) + content.dropFirst()
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
        var unnumbered: OrgInstructionSource?
        for i in (next + 1)..<end {
            let line = lines[i]
            if let property = orgCaptures(#"^\s*:([^\s:]+):\s*(.*?)\s*$"#, line) {
                let key = property[0].uppercased()
                properties[key] = property[1]
                if key == "UNNUMBERED" {
                    unnumbered = .init(
                        fileName: context.fileName, lineNumber: i + 1,
                        rawText: line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        if let unnumbered {
            context.options.file.note(.unnumberedHeading, source: unnumbered)
            if properties["UNNUMBERED"] == "notoc" {
                context.options.file.note(.excludedFromContents, source: unnumbered)
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

    private func renderHeading(_ headline: OrgHeadline) -> (html: String, title: String, contents: String) {
        var text = headline.title
        var prefix = ""
        var tags = ""
        let keyword = headline.keyword
        let isTask = context.taskKeywords.contains(keyword)
        if isTask || context.reading.todo && (context.active.contains(keyword) || context.done.contains(keyword)) {
            if context.reading.todo {
                prefix +=
                    "<span class=\"org-\(context.done.contains(keyword) ? "done" : "todo")\">\(HTML.escape(keyword))</span> "
            }
            text = text.dropFirst(keyword.count).drop(while: \.isWhitespace)
        }
        let cookie = text.prefix { !$0.isWhitespace }
        if OrgHeadline.isPriority(cookie) {
            if context.reading.priority {
                prefix += "<span class=\"org-priority\">\(HTML.escape(String(cookie.dropFirst().dropLast())))</span> "
            }
            text = text[cookie.endIndex...].drop(while: \.isWhitespace)
        }
        if !headline.tags.isEmpty {
            tags =
                " <span class=\"org-tags\">"
                + headline.tags.map { "<span class=\"org-tag\">\(HTML.escape(String($0)))</span>" }
                .joined(separator: " ") + "</span>"
        }
        let title = inline(String(text), cookies: .all)
        let heading = prefix + title
        return (
            heading + (context.reading.tags == .off ? "" : tags), title,
            heading + (context.reading.tags == .all ? tags : "")
        )
    }

    private mutating func renderTable() -> String {
        var rows: [[String]?] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            // Org takes any row that starts with `|-` as a rule, whatever follows (`|---+---|--|` too).
            if line.hasPrefix("|-") {
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
        let start = index
        index += 1
        let content = [firstLine] + collectListItemContinuation(indent: item.indent)
        if let term {
            output += "<dt>\(term)</dt><dd>"
            return Child(lines: content, startInParent: start, closing: "</dd>")
        }
        let task = orgCaptures(#"^\[([ Xx-])\]\s*([\s\S]*)$"#, firstLine) != nil
        output += task ? "<li class=\"task-list-item\">" : "<li>"
        return Child(lines: content, startInParent: start, isListItem: true, closing: "</li>")
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
            if line.isEmpty || position > start && headlines[position] != nil {
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
            position += 1
            guard let note = context.notes[label] else { continue }
            var nested = OrgParser(
                lines: (context.definitions[label] ?? "").components(separatedBy: "\n"),
                depth: note.depth + 1, context: context)
            // A shifted anchor no longer encodes the printed number. Mark this series explicitly
            // so page-bottom placement can distinguish it from a restarted or symbolic series.
            let numbering =
                note.id == "fn-\(note.number)" ? "" : " value=\"\(note.number)\" class=\"numbered-footnote\""
            items += "<li id=\"\(note.id)\"\(numbering)>\(nested.render())</li>\n"
        }
        return items.isEmpty ? "" : "<section class=\"footnotes\">\n<ol>\n\(items)</ol>\n</section>\n"
    }

}
