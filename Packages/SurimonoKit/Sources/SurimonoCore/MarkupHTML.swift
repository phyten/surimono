import Foundation
// Surimono never installs custom libxml allocators. Its allocation hooks are read-only here.
@preconcurrency import libxml2

// Parse as UTF-8 HTML, including passthrough fragments with HTML void tags and named entities.
// The borrowed nodes never escape withBody(), which owns the libxml document for the whole traversal.
struct MarkupElement {
    let ptr: xmlNodePtr
    var name: String { String(cString: ptr.pointee.name) }
    var text: String {
        guard let value = xmlNodeGetContent(ptr) else { return "" }
        defer { xmlFree(value) }
        return String(cString: value)
    }
    var children: [MarkupElement] {
        var nodes: [MarkupElement] = []
        var child = ptr.pointee.children
        while let current = child {
            nodes.append(MarkupElement(ptr: current))
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
    func child(_ name: String) -> MarkupElement? { children.first { $0.name == name } }
    func member(_ cls: String) -> MarkupElement? { children.first { $0.has(cls) } }
    var id: String { attribute("id").map { " id=\"\(HTML.escape($0))\"" } ?? "" }
    func wrapped(_ inner: () -> String) -> String {
        let opening = "<\(name)\(attributes)>"
        if [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
            "wbr",
        ].contains(name) {
            return opening
        }
        return opening + inner() + "</\(name)>"
    }

    var attributes: String { attributes(excluding: []) }
    func attributes(excluding excluded: Set<String>) -> String {
        var result = ""
        var attr = ptr.pointee.properties
        while let current = attr {
            let key = String(cString: current.pointee.name)
            if !excluded.contains(key), !key.lowercased().hasPrefix("on"), let value = attribute(key) {
                result += " \(key)=\"\(HTML.escape(value))\""
            }
            attr = current.pointee.next
        }
        return result
    }
}

enum MarkupHTML {
    static func withBody<T>(_ fragment: String, _ visit: (MarkupElement) throws -> T) throws -> T {
        let source = "<html><body>" + fragment + "</body></html>"
        let flags = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard let size = Int32(exactly: source.utf8.count),
            let doc = htmlReadMemory(source, size, nil, "UTF-8", Int32(flags))
        else { throw CocoaError(.fileReadCorruptFile) }
        defer { xmlFreeDoc(doc) }
        guard let root = xmlDocGetRootElement(doc), let body = MarkupElement(ptr: root).child("body") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try visit(body)
    }

    static func listing(_ source: String, language: String?) -> String {
        guard let language, !language.isEmpty else { return "<pre><code>\(HTML.escape(source))</code></pre>" }
        if language == "mermaid" { return MermaidBlock.html(source) }
        if let format = DiagramConverter.format(language: language) {
            return DiagramConverter.block(source, format: format)
        }
        let highlighted = SyntaxHighlighter.highlight(source, language: language)
        let cls = HTML.escape(language) + (highlighted == nil ? "" : " hl")
        return "<pre><code class=\"language-\(cls)\">\(highlighted ?? HTML.escape(source))</code></pre>"
    }
}
