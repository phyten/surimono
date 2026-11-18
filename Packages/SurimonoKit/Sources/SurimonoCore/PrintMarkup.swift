import Foundation
@preconcurrency import libxml2

// All borrowed elements and document-specific numbering live inside withBody's lifetime.
private final class PrintMarkupWriter {
    let format: DocumentFormat
    private(set) var title: String?
    private(set) var wordTitle: String?
    private var headings: [xmlNodePtr: String] = [:]
    private var aliases: [String: String] = [:]
    private var definitions: [String: MarkupElement] = [:]
    private var noteOrder: [String] = []
    private var numbers: [String: Int] = [:]
    private var references: [String: Int] = [:]

    private var vectorLabels: [String: [String]]
    private var numbering: DocxNumbering?

    init(format: DocumentFormat, numbering: DocxNumbering?, vectorLabels: [String: [String]]) {
        self.format = format
        self.vectorLabels = vectorLabels
        self.numbering = numbering
    }

    private func numberedList(_ node: MarkupElement) -> String {
        var start = ""
        var items = ""
        var expected = 1
        var first = true
        for item in node.children {
            guard item.name == "li" else {
                items += render(item)
                continue
            }
            let label = item.children.filter { !["ol", "ul"].contains($0.name) }.map(\.text).joined()
            let value = numbering?.take(for: label) ?? expected
            var attribute = ""
            if value != expected {
                if first { start = " start=\"\(value)\"" } else { attribute = " value=\"\(value)\"" }
            }
            expected = value == Int.max ? value : value + 1
            first = false
            items += "<li\(attribute)\(item.attributes)>\(inner(item))</li>"
        }
        return "<ol\(start)\(node.attributes)>\(items)</ol>"
    }

    func index(_ body: MarkupElement) {
        var automatic: [MarkupElement] = []
        var occupied: Set<String> = []
        var suffixes: [String: Int] = [:]
        func visit(_ node: MarkupElement) {
            guard node.ptr.pointee.type == XML_ELEMENT_NODE, node.name != "script" else { return }
            let explicit = node.attribute("id")
            if let explicit { occupied.insert(explicit) }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(node.name) {
                if explicit == nil { automatic.append(node) }
                if format == .docx, wordTitle == nil, node.has("org-title") { wordTitle = node.text }
                if title == nil, node.name == "h1" { title = node.text }
            }
            if isDefinition(node), let explicit { definitions["#" + explicit] = node }
            node.children.forEach(visit)
        }
        visit(body)
        // Reserve author-specified anchors even when a matching automatic heading occurs first.
        for node in automatic {
            let slug = MarkdownExtensions.slug(node.text)
            let base = slug.isEmpty ? "section" : slug
            var id = base
            while !occupied.insert(id).inserted {
                suffixes[base, default: 0] += 1
                id = "\(base)-\(suffixes[base, default: 0])"
            }
            headings[node.ptr] = id
            if let old = node.attribute("data-djot-auto") { aliases["#" + old] = "#" + id }
        }
    }

    private func isDefinition(_ node: MarkupElement) -> Bool {
        if format == .docx, node.name == "li", let id = node.attribute("id") {
            return id.hasPrefix("footnote-") || id.hasPrefix("endnote-")
        }
        if format == .textile { return node.name == "p" && node.has("footnote") }
        guard node.name == "li", let section = node.ptr.pointee.parent?.pointee.parent else { return false }
        return MarkupElement(ptr: section).attribute("role") == "doc-endnotes"
    }

    private func reference(_ key: String) -> String {
        if numbers[key] == nil {
            noteOrder.append(key)
            numbers[key] = noteOrder.count
        }
        let number = numbers[key, default: 1]
        references[key, default: 0] += 1
        let count = references[key, default: 1]
        let suffix = count == 1 ? "" : "-\(count)"
        return
            "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\(suffix)\">\(number)</a></sup>"
    }

    func notes() -> String {
        guard !noteOrder.isEmpty else { return "" }
        var items = ""
        var index = 0
        // Notes can themselves introduce references, including cycles.
        while index < noteOrder.count {
            let key = noteOrder[index]
            index += 1
            guard let note = definitions[key] else { continue }
            items += "<li id=\"fn-\(index)\">" + inner(note) + "</li>"
        }
        return "<section class=\"footnotes\"><ol>" + items + "</ol></section>"
    }

    func inner(_ node: MarkupElement) -> String {
        guard format == .docx else { return node.children.map(render).joined() }
        let nodes = node.children
        var result = ""
        var index = 0
        while index < nodes.count {
            let current = nodes[index]
            index += 1
            if index < nodes.count {
                let next = nodes[index]
                if current.has("docx-caption"), let figure = captioned(next, caption: current) {
                    result += figure
                    index += 1
                    continue
                }
                if next.has("docx-caption"), let figure = captioned(current, caption: next) {
                    result += figure
                    index += 1
                    continue
                }
            }
            result += render(current)
        }
        return result
    }

    private func captioned(_ node: MarkupElement, caption: MarkupElement) -> String? {
        if node.name == "table" {
            return "<table\(node.attributes)><caption>\(inner(caption))</caption>\(inner(node))</table>"
        }
        if node.name == "p", node.children.count == 1, node.child("img") != nil {
            return "<figure>\(inner(node))<figcaption>\(inner(caption))</figcaption></figure>"
        }
        return nil
    }

    func render(_ node: MarkupElement) -> String {
        if node.ptr.pointee.type == XML_TEXT_NODE || node.ptr.pointee.type == XML_CDATA_SECTION_NODE {
            return HTML.escape(node.text)
        }
        guard node.ptr.pointee.type == XML_ELEMENT_NODE, node.name != "script" else { return "" }
        if format == .docx, let html = wordElement(node) { return html }
        let role = node.attribute("role")
        if role == "doc-endnotes" || role == "doc-backlink" || isDefinition(node) { return "" }
        if node.name == "a", let href = node.attribute("href") {
            if role == "doc-noteref", definitions[href] != nil { return reference(href) }
            if format == .textile, let parent = node.ptr.pointee.parent,
                isDefinition(MarkupElement(ptr: parent)), href.hasPrefix("#fnr")
            {
                return ""
            }
            if let replacement = aliases[href] {
                return
                    "<a href=\"\(HTML.escape(replacement))\"\(node.attributes(excluding: ["href"]))>\(inner(node))</a>"
            }
        }
        if node.name == "sup", format == .docx || node.has("footnote"), let key = node.child("a")?.attribute("href"),
            definitions[key] != nil
        {
            return reference(key)
        }
        if let id = headings[node.ptr] {
            let attributes = node.attributes(excluding: ["id", "data-djot-auto"])
            return
                "<\(node.name) id=\"\(HTML.escape(id))\"\(attributes)>\(inner(node))</\(node.name)>"
        }
        if node.name == "pre" {
            let code = node.child("code")
            let classes = (code?.attribute("class") ?? node.attribute("class") ?? "").split(separator: " ")
            let language =
                classes.first(where: { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)) }
                ?? (format == .textile ? classes.first.map(String.init) : nil)
            let listing = MarkupHTML.listing(node.text, language: language)
            return node.attributes.isEmpty ? listing : "<div\(node.attributes)>\(listing)</div>"
        }
        if node.name == "li", node.child("input")?.attribute("type") == "checkbox" {
            return task(node, contents: inner(node))
        }
        if node.name == "li", format == .textile, let first = node.children.first,
            first.ptr.pointee.type == XML_TEXT_NODE,
            ["[x] ", "[X] ", "[ ] "].contains(String(first.text.prefix(4)))
        {
            let box = "<input type=\"checkbox\" disabled" + (first.text.hasPrefix("[ ]") ? ">" : " checked>")
            return task(
                node,
                contents: box + HTML.escape(String(first.text.dropFirst(4)))
                    + node.children.dropFirst().map(render).joined())
        }
        if format == .djot {
            if node.attribute("data-djot-symbol") != nil {
                let symbol = HTML.escape(MarkdownExtensions.emojified(":" + node.text + ":"))
                return span(symbol, attributes: node.attributes(excluding: ["data-djot-symbol"]))
            }
            if let type = node.attribute("data-djot-math") {
                let display = type == "display_math"
                let math =
                    MathRenderer.html(node.text, display: display) ?? MathRenderer.fallback(node.text, display: display)
                return span(math, attributes: node.attributes(excluding: ["data-djot-math"]))
            }
            if node.attribute("data-djot-div") != nil {
                let classes = node.attribute("class") ?? ""
                let kinds = classes.split(separator: " ").map { MarkdownCallouts.Kind(name: String($0)) }
                if let kind = kinds.first(where: { $0.canonicalName != nil }) {
                    let attributes = node.attributes(excluding: ["class", "data-callout", "data-djot-div"])
                    return kind.opening(extraClasses: classes, attributes: attributes) + kind.title(kind.defaultTitle)
                        + inner(node) + "</div>"
                }
                return "<div\(node.attributes(excluding: ["data-djot-div"]))>\(inner(node))</div>"
            }
        }
        return node.wrapped { inner(node) }
    }

    private func wordElement(_ node: MarkupElement) -> String? {
        if node.name == "ol", node.children.contains(where: isDefinition) { return "" }
        if node.name == "ol", numbering != nil { return numberedList(node) }
        if node.name == "a", let href = node.attribute("href"),
            href.hasPrefix("#footnote-ref-") || href.hasPrefix("#endnote-ref-"), node.text == "↑"
        {
            return ""
        }
        if node.name == "img", let src = node.attribute("src"),
            let mime = src.prefix(64).split(separator: ";").first,
            mime.hasSuffix("emf") || mime.hasSuffix("wmf")
        {
            var alt = node.attribute("alt") ?? ""
            if alt.isEmpty, !vectorLabels.isEmpty, let comma = src.firstIndex(of: ",") {
                alt = vectorLabels[String(src.suffix(from: src.index(after: comma)))]?.popLast() ?? ""
            }
            let label = mime.hasSuffix("emf") ? "EMF" : "WMF"
            return "<span class=\"docx-image-note\">\(label) \(HTML.escape(alt))</span>"
        }
        if node.name == "p", node.children.contains(where: { $0.name == "br" && $0.has("page-break") }) {
            var html = ""
            var line = ""
            for child in node.children {
                if child.name == "br", child.has("page-break") {
                    if !line.isEmpty { html += "<p\(node.attributes)>\(line)</p>" }
                    html += "<div class=\"page-break\"></div>"
                    line = ""
                } else {
                    line += render(child)
                }
            }
            return html + (line.isEmpty ? "" : "<p\(node.attributes)>\(line)</p>")
        }
        if node.name == "pre" {
            let code = node.child("code") ?? node
            let text = code.children.map { $0.name == "br" ? "\n" : $0.text }.joined()
            return MarkupHTML.listing(text, language: nil)
        }
        return nil
    }

    private func span(_ contents: String, attributes: String) -> String {
        attributes.isEmpty ? contents : "<span\(attributes)>\(contents)</span>"
    }

    private func task(_ node: MarkupElement, contents: String) -> String {
        let classes = ["task-list-item", node.attribute("class")].compactMap { $0 }.joined(separator: " ")
        return "<li class=\"\(HTML.escape(classes))\"\(node.attributes(excluding: ["class"]))>\(contents)</li>"
    }
}

enum PrintMarkup {
    static func fragment(
        _ html: String, format: DocumentFormat, metadataTitle: String? = nil, numbering: DocxNumbering? = nil,
        vectorLabels: [String: [String]] = [:]
    ) throws -> HTMLFragment {
        try MarkupHTML.withBody(html) { body in
            let writer = PrintMarkupWriter(format: format, numbering: numbering, vectorLabels: vectorLabels)
            writer.index(body)
            var html = writer.inner(body)
            html += writer.notes()
            let fonts = MathRenderer.fontFaces(for: html)
            if !fonts.isEmpty { html += "<style>\(fonts)</style>" }
            return HTMLFragment(body: html, title: writer.wordTitle ?? metadataTitle ?? writer.title)
        }
    }
}
