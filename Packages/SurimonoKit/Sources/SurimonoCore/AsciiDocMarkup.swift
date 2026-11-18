import Foundation
// Surimono never installs custom libxml allocators. Its allocation hooks are read-only here.
@preconcurrency import libxml2

// Parse as UTF-8 HTML, including passthrough fragments with HTML void tags and named entities.
// The borrowed nodes never escape fragment(), which owns the libxml document for the whole traversal.
private struct Element {
    let ptr: xmlNodePtr
    var name: String { String(cString: ptr.pointee.name) }
    var text: String {
        guard let value = xmlNodeGetContent(ptr) else { return "" }
        defer { xmlFree(value) }
        return String(cString: value)
    }
    var children: [Element] {
        var nodes: [Element] = []
        var child = ptr.pointee.children
        while let current = child {
            nodes.append(Element(ptr: current))
            child = current.pointee.next
        }
        return nodes
    }
    func attribute(_ name: String) -> String? {
        guard let value = xmlGetProp(ptr, name) else { return nil }
        defer { xmlFree(value) }
        return String(cString: value)
    }
    func has(_ cls: String) -> Bool { attribute("class")?.split(separator: " ").contains(Substring(cls)) == true }
    func child(_ name: String) -> Element? { children.first { $0.name == name } }
    func member(_ cls: String) -> Element? { children.first { $0.has(cls) } }
    var id: String { attribute("id").map { " id=\"\(HTML.escape($0))\"" } ?? "" }
    var attributes: String {
        var result = ""
        var attr = ptr.pointee.properties
        while let current = attr {
            let key = String(cString: current.pointee.name)
            if !key.lowercased().hasPrefix("on"), let value = attribute(key) {
                result += " \(key)=\"\(HTML.escape(value))\""
            }
            attr = current.pointee.next
        }
        return result
    }
}

enum AsciiDocMarkup {
    static func fragment(_ parts: AsciiDocParts) throws -> HTMLFragment {
        let source = "<html><body>" + parts.html + "</body></html>"
        let flags = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard let size = Int32(exactly: source.utf8.count),
            let doc = htmlReadMemory(source, size, nil, "UTF-8", Int32(flags))
        else { throw CocoaError(.fileReadCorruptFile) }
        defer { xmlFreeDoc(doc) }
        guard let root = xmlDocGetRootElement(doc), let body = Element(ptr: root).child("body") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let title = body.child("h1")
        var html = ""
        for child in body.children {
            if child.ptr == title?.ptr {
                html += "<header class=\"org-title-block\"><h1 class=\"org-title\"\(child.id)>\(inner(child))</h1>"
                for (cls, text) in [("author", parts.author), ("date", parts.revision)] where !text.isEmpty {
                    html += "<p class=\"org-\(cls)\">\(HTML.escape(text))</p>"
                }
                html += "</header>"
            } else {
                html += render(child)
            }
        }
        let fonts = MathRenderer.fontFaces(for: html)
        if !fonts.isEmpty { html += "<style>\(fonts)</style>" }
        return HTMLFragment(body: html, title: title?.text, language: parts.language)
    }

    private static func inner(_ node: Element) -> String { node.children.map(render).joined() }

    private static func render(_ node: Element) -> String {
        if node.ptr.pointee.type == XML_CDATA_SECTION_NODE { return node.text }
        if node.ptr.pointee.type == XML_TEXT_NODE { return HTML.escape(node.text) }
        guard node.ptr.pointee.type == XML_ELEMENT_NODE, node.name != "script" else { return "" }
        if node.name == "div" {
            if node.has("listingblock") || node.has("literalblock"), let pre = node.member("content")?.child("pre") {
                return figure(node, content: listing(pre))
            }
            if node.has("imageblock"), let content = node.member("content") {
                return figure(node, content: inner(content))
            }
            if node.has("stemblock"), let content = node.member("content") {
                let delimited = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let latex = delimited.hasPrefix("\\[") && delimited.hasSuffix("\\]")
                let source = String(delimited.dropFirst(2).dropLast(2))
                return figure(
                    node, content: "<div class=\"math-block\">\(math(source, latex: latex, display: true))</div>")
            }
            if node.has("admonitionblock"), let row = node.child("table")?.child("tr"),
                let content = row.member("content"), let label = row.member("icon")?.member("title")
            {
                let kind = MarkdownCallouts.Kind(
                    name: node.attribute("class")?.split(separator: " ").dropFirst().first.map(String.init) ?? "note")
                return kind.opening + kind.title(inner(label)) + inner(content) + "</div>"
            }
            if node.attribute("id") == "footnotes" {
                return "<section class=\"footnotes\"><ol>"
                    + node.children.filter { $0.has("footnote") }.map { note in
                        let number = note.child("a")?.text ?? ""
                        let rest = note.children.drop(while: { $0.name != "a" }).dropFirst().map(render).joined()
                        return "<li id=\"fn-\(HTML.escape(number))\">"
                            + String(rest.drop(while: { $0 == "." || $0 == " " })) + "</li>"
                    }.joined() + "</ol></section>"
            }
            if node.has("toc") { return "<nav class=\"toc\"\(node.id)>\(inner(node))</nav>" }
            // Theme selectors (including direct children and adjacent paragraphs) expect ordinary document flow.
            if node.id.isEmpty
                && (node.has("paragraph") || node.has("sectionbody") || node.has("content")
                    || (1...6).contains(where: { node.has("sect\($0)") }))
            {
                return inner(node)
            }
        }
        if node.name == "li", let parent = node.ptr.pointee.parent, Element(ptr: parent).has("checklist"),
            let paragraph = node.child("p"), let first = paragraph.children.first
        {
            let checked = first.name == "input" ? first.attribute("checked") != nil : first.text.hasPrefix("✓ ")
            if first.name == "input" || first.text.hasPrefix("❏ ") || checked {
                let box = "<input type=\"checkbox\" disabled" + (checked ? " checked>" : ">")
                let remainder = first.name == "input" ? "" : HTML.escape(String(first.text.dropFirst(2)))
                let content = paragraph.children.dropFirst().map(render).joined()
                let items = node.children.map {
                    $0.ptr == paragraph.ptr ? "<p>" + box + remainder + content + "</p>" : render($0)
                }.joined()
                return "<li class=\"task-list-item\"\(node.id)>\(items)</li>"
            }
        }
        if node.name == "sup", node.has("footnote") || node.has("footnoteref"), let link = node.child("a") {
            let number = HTML.escape(link.text)
            let id = link.attribute("id") == nil ? "" : " id=\"fnref-\(number)\""
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(number)\"\(id)>\(number)</a></sup>"
        }
        if node.name == "a", node.has("include") {
            return "<span class=\"callout callout-note adoc-include\">include::\(inner(node))[]</span>"
        }
        if let type = node.attribute("data-adoc-math") {
            return math(node.text, latex: type == "latexmath", display: false)
        }
        let opening = "<\(node.name)\(node.attributes)>"
        if [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
            "wbr",
        ].contains(node.name) {
            return opening
        }
        return opening + inner(node) + "</\(node.name)>"
    }

    private static func listing(_ pre: Element) -> String {
        let source = pre.text
        guard let language = pre.child("code")?.attribute("data-lang") else {
            return "<pre><code>\(HTML.escape(source))</code></pre>"
        }
        if language == "mermaid" { return MermaidBlock.html(source) }
        if let format = DiagramConverter.format(language: language) {
            return DiagramConverter.block(source, format: format)
        }
        let highlighted = SyntaxHighlighter.highlight(source, language: language)
        let cls = HTML.escape(language) + (highlighted == nil ? "" : " hl")
        return "<pre><code class=\"language-\(cls)\">\(highlighted ?? HTML.escape(source))</code></pre>"
    }

    private static func figure(_ node: Element, content: String) -> String {
        guard let title = node.member("title") else {
            return node.id.isEmpty ? content : "<div\(node.id)>\(content)</div>"
        }
        return "<figure class=\"org-figure\"\(node.id)>\(content)<figcaption>\(inner(title))</figcaption></figure>"
    }

    private static func math(_ source: String, latex: Bool, display: Bool) -> String {
        if latex, let rendered = MathRenderer.html(source, display: display) { return rendered }
        return MathRenderer.fallback(source, display: display)
    }
}
