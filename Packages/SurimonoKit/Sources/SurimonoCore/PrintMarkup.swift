import Foundation
@preconcurrency import libxml2

// All borrowed elements and document-specific numbering live inside withBody's lifetime.
private final class PrintMarkupWriter {
    let format: DocumentFormat
    private(set) var title: String?
    private var headings: [xmlNodePtr: String] = [:]
    private var aliases: [String: String] = [:]
    private var definitions: [String: MarkupElement] = [:]
    private var noteOrder: [String] = []
    private var numbers: [String: Int] = [:]
    private var references: [String: Int] = [:]

    init(format: DocumentFormat) { self.format = format }

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

    func inner(_ node: MarkupElement) -> String { node.children.map(render).joined() }

    func render(_ node: MarkupElement) -> String {
        if node.ptr.pointee.type == XML_TEXT_NODE || node.ptr.pointee.type == XML_CDATA_SECTION_NODE {
            return HTML.escape(node.text)
        }
        guard node.ptr.pointee.type == XML_ELEMENT_NODE, node.name != "script" else { return "" }
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
        if node.name == "sup", node.has("footnote"), let key = node.child("a")?.attribute("href"),
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

    private func span(_ contents: String, attributes: String) -> String {
        attributes.isEmpty ? contents : "<span\(attributes)>\(contents)</span>"
    }

    private func task(_ node: MarkupElement, contents: String) -> String {
        let classes = ["task-list-item", node.attribute("class")].compactMap { $0 }.joined(separator: " ")
        return "<li class=\"\(HTML.escape(classes))\"\(node.attributes(excluding: ["class"]))>\(contents)</li>"
    }
}

enum PrintMarkup {
    static func fragment(_ html: String, format: DocumentFormat) throws -> HTMLFragment {
        try MarkupHTML.withBody(html) { body in
            let writer = PrintMarkupWriter(format: format)
            writer.index(body)
            var html = writer.inner(body)
            html += writer.notes()
            let fonts = MathRenderer.fontFaces(for: html)
            if !fonts.isEmpty { html += "<style>\(fonts)</style>" }
            return HTMLFragment(body: html, title: writer.title)
        }
    }
}
