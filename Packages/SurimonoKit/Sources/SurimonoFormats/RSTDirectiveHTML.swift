import Foundation
@preconcurrency import libxml2

extension RSTDocument {
    /// Raw HTML may carry its own typography or drawing. Only the ordinary, checked image route may fetch bytes.
    func rstRawHTML(_ source: String) -> String {
        func visit(_ node: MarkupElement) -> String {
            if node.ptr.pointee.type == XML_TEXT_NODE || node.ptr.pointee.type == XML_CDATA_SECTION_NODE {
                return HTML.escape(node.text)
            }
            guard node.ptr.pointee.type == XML_ELEMENT_NODE else { return "" }
            if ["style", "script", "template"].contains(node.name) { return "" }
            if node.name == "svg" { return rstStaticSVG(node) }
            if node.name == "img" {
                let options = ["height", "width"].reduce(into: ["alt": node.attribute("alt") ?? ""]) { result, key in
                    result[key] = node.attribute(key)
                }
                return rstImage(node.attribute("src") ?? "", options: options)
            }
            let body = node.children.map(visit).joined()
            guard Self.rawTags.contains(node.name) else { return body }
            var attrs = ""
            for key in ["id", "class", "lang", "dir", "title", "colspan", "rowspan", "start", "type", "display"] {
                if let value = node.attribute(key) { attrs += " \(key)=\"\(HTML.escape(value))\"" }
            }
            if let style = node.attribute("style") {
                let safe = Self.rstStaticStyle(style)
                if !safe.isEmpty { attrs += " style=\"\(HTML.escape(safe))\"" }
            }
            if node.name == "a", let href = node.attribute("href"), let link = rstStaticLink(href) {
                attrs += " href=\"\(HTML.escape(link))\""
            }
            let void = ["br", "col", "hr", "wbr"].contains(node.name)
            return "<\(node.name)\(attrs)>" + (void ? "" : body + "</\(node.name)>")
        }
        return (try? MarkupHTML.withBody(source) { $0.children.map(visit).joined() }) ?? HTML.escape(source)
    }

    private static let rawTags: Set<String> = [
        "a", "abbr", "address", "article", "aside", "b", "bdi", "bdo", "blockquote", "br", "caption", "cite",
        "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "ins", "kbd", "li",
        "main", "mark", "nav", "ol", "p", "pre", "q", "rb", "rp", "rt", "ruby", "s", "samp", "section",
        "small", "span", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead",
        "time", "tr", "u", "ul", "var", "wbr", "math", "mrow", "mi", "mn", "mo", "mtext", "ms", "mfrac",
        "msqrt", "mroot", "mspace", "mpadded", "mphantom", "msub", "msup", "msubsup", "munder", "mover",
        "munderover", "mmultiscripts", "mprescripts", "mtable", "mtr", "mtd", "mstyle", "merror",
    ]

    private static let styleProperties: Set<String> = [
        "color", "background-color", "font", "font-family", "font-size", "font-style", "font-weight",
        "line-height", "letter-spacing", "word-spacing", "white-space", "text-align", "text-decoration",
        "text-indent", "text-transform", "vertical-align", "width", "min-width", "max-width", "height",
        "min-height", "max-height", "padding", "padding-left", "padding-right", "padding-top", "padding-bottom",
        "margin", "margin-left", "margin-right", "margin-top", "margin-bottom", "border", "border-width",
        "border-style", "border-color", "border-radius", "border-collapse", "opacity", "text-anchor",
        "fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity",
    ]

    private static func rstStaticStyle(_ style: String) -> String {
        style.split(separator: ";").compactMap { declaration -> String? in
            guard let split = declaration.firstIndex(of: ":") else { return nil }
            let property = String(declaration[..<split]).rstStripped.lowercased()
            let value = String(declaration[declaration.index(after: split)...]).rstStripped
            guard styleProperties.contains(property), safeStyleValue(value) else { return nil }
            return "\(property):\(value)"
        }.joined(separator: ";")
    }

    private static func safeStyleValue(_ value: String) -> Bool {
        // Only numeric/colour functions are useful for these properties. CSS escapes, comments, URL and
        // custom property references could smuggle an external paint server into an otherwise static SVG.
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_+.%#,'\"()"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let functions = ["rgb", "rgba", "hsl", "hsla", "calc", "min", "max", "clamp"]
        var name = ""
        for char in value {
            if char.isLetter {
                name.append(char)
            } else {
                if char == "(", !functions.contains(name.lowercased()) { return false }
                name = ""
            }
        }
        return true
    }

    /// libxml's HTML reader lowercases element and attribute names; restore the spelling required by SVG.
    private func rstStaticSVG(_ root: MarkupElement) -> String {
        let names = [
            "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan",
            "title", "desc", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "use", "symbol",
        ]
        let tags = Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
        let attributes = [
            "id", "class", "viewBox", "preserveAspectRatio", "width", "height", "x", "y", "x1", "y1", "x2", "y2",
            "cx", "cy", "r", "rx", "ry", "points", "d", "transform", "fill-rule", "stroke-width", "stroke-dasharray",
            "stroke-linecap", "stroke-linejoin", "opacity", "fill-opacity", "stroke-opacity", "offset", "text-anchor",
            "font-family", "font-size", "font-weight", "gradientUnits", "gradientTransform",
        ]
        func paint(_ value: String) -> Bool {
            Self.safeStyleValue(value)
                || value.range(of: #"^url\(#[a-zA-Z_][\w.-]*\)$"#, options: .regularExpression) != nil
        }
        func draw(_ node: MarkupElement) -> String {
            if node.ptr.pointee.type == XML_TEXT_NODE { return HTML.escape(node.text) }
            guard node.ptr.pointee.type == XML_ELEMENT_NODE, let tag = tags[node.name] else { return "" }
            var attrs = tag == "svg" ? " xmlns=\"http://www.w3.org/2000/svg\"" : ""
            for key in attributes {
                if let value = node.attribute(key.lowercased()) { attrs += " \(key)=\"\(HTML.escape(value))\"" }
            }
            for key in ["fill", "stroke", "stop-color", "clip-path"] {
                if let value = node.attribute(key), paint(value) { attrs += " \(key)=\"\(HTML.escape(value))\"" }
            }
            if let style = node.attribute("style") { attrs += " style=\"\(HTML.escape(Self.rstStaticStyle(style)))\"" }
            if tag == "use", let href = node.attribute("href") ?? node.attribute("xlink:href"), href.hasPrefix("#") {
                attrs += " href=\"\(HTML.escape(href))\""
            }
            return "<\(tag)\(attrs)>\(node.children.map(draw).joined())</\(tag)>"
        }
        return draw(root)
    }
}
