import Foundation
@preconcurrency import libxml2

enum AsciiDocMarkup {
    /// On a stack of known size, so a document reads the same on every thread.
    static func fragment(_ parts: ScriptDocument) throws -> HTMLFragment {
        try StackSpace.onLargeStack { () throws -> HTMLFragment in
            let (fragment, reachedLimit) = try StackSpace.collectingLimit { () throws -> HTMLFragment in
                try fragmentInPlace(parts)
            }
            return fragment.notingLimit(reachedLimit)
        }
    }

    private static func fragmentInPlace(_ parts: ScriptDocument) throws -> HTMLFragment {
        try MarkupHTML.withBody(parts.html) { body in
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
            if parts.leadContents == "true", let nav = html.range(of: "<nav class=\"toc\"") {
                html.replaceSubrange(nav, with: ReaderContentsKind.lead.mark(String(html[nav])))
            }
            var fragment = HTMLFragment(
                body: html, title: title?.text, language: parts.language == "und" ? nil : parts.language
            ).recordingContents(
                .init(
                    present: parts.leadContents.map { .init($0 == "true") },
                    depth: parts.contentsDepth.flatMap(Int.init).map { .init(.levels(max(1, $0))) }))
            fragment.coalescesContentsInLegacy = parts.combinedContents
            return fragment
        }
    }

    private static func inner(_ node: MarkupElement) -> String { node.children.map(render).joined() }

    private static func render(_ node: MarkupElement) -> String {
        if node.ptr.pointee.type == XML_CDATA_SECTION_NODE { return node.text }
        if node.ptr.pointee.type == XML_TEXT_NODE { return HTML.escape(node.text) }
        guard node.ptr.pointee.type == XML_ELEMENT_NODE, node.name != "script" else { return "" }
        // libxml2 nests elements up to 256 deep, more than a 512 KiB stack holds here in a debug build.
        guard StackSpace.hasRoom else {
            StackSpace.noteLimitReached()
            return "<p>\(HTML.escape(node.text))</p>"
        }
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
            if node.has("toc") {
                let nav = "<nav class=\"toc\"\(node.id)>\(inner(node))</nav>"
                return node.attribute("data-surimono-in-text") == "1" ? ReaderContentsKind.text.mark(nav) : nav
            }
            // Theme selectors (including direct children and adjacent paragraphs) expect ordinary document flow.
            if node.id.isEmpty
                && (node.has("paragraph") || node.has("sectionbody") || node.has("content")
                    || (1...6).contains(where: { node.has("sect\($0)") }))
            {
                return inner(node)
            }
        }
        if node.name == "li", let parent = node.ptr.pointee.parent, MarkupElement(ptr: parent).has("checklist"),
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
        return node.wrapped { inner(node) }
    }

    private static func listing(_ pre: MarkupElement) -> String {
        MarkupHTML.listing(pre.text, language: pre.child("code")?.attribute("data-lang"))
    }

    private static func figure(_ node: MarkupElement, content: String) -> String {
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
