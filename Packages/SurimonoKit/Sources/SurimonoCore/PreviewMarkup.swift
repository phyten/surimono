import Foundation

/// Reconstructs inert markup. The Finder HTML renderer is outside the provider's sandbox.
enum PreviewMarkup {
    private static let elements: Set<String> = [
        "a", "abbr", "article", "aside", "b", "blockquote", "br", "caption", "cite", "code", "col", "colgroup",
        "dd", "del", "details", "div", "dl", "dt", "em", "figcaption", "figure", "footer", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "i", "img", "kbd", "li", "main", "mark", "nav", "ol", "p", "pre",
        "q", "rp", "rt", "ruby", "s", "samp", "section", "small", "span", "strong", "sub", "summary", "sup",
        "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr", "u", "ul", "var", "wbr",
    ]
    private static let svgElements: Set<String> = [
        "svg", "g", "text", "tspan", "path", "rect", "line", "circle", "ellipse", "polygon", "polyline",
    ]
    private static let attributes: Set<String> = [
        "id", "class", "title", "alt", "lang", "dir", "role", "aria-label", "start", "open", "colspan", "rowspan",
        "scope", "align", "data-no", "width", "height", "viewbox", "x", "y", "x1", "y1", "x2", "y2", "rx", "ry", "cx",
        "cy", "r", "points", "d", "transform", "fill-rule", "stroke-width", "stroke-linecap", "stroke-linejoin",
        "font-family", "font-size", "font-style", "font-weight", "dominant-baseline", "text-anchor",
    ]
    private static let styleProperties: Set<String> = [
        "vertical-align", "overflow", "font-weight", "font-style", "text-align", "width", "height", "max-width",
        "max-height", "color", "background-color", "object-fit", "white-space",
    ]

    static func clean(_ body: String, svgOnly: Bool = false, imageSource: (String) -> String?) throws -> String {
        var output = ""
        var tagCount = 0
        var excluded: (name: String, depth: Int)?
        try HTMLScanner.forEachToken(body) { token in
            try PreviewConversion.check()
            if case .tag = token {
                tagCount += 1
                guard tagCount <= 250_000 else { throw FinderPreview.Failure.complexity }
            }
            if var element = excluded {
                if case .tag(let tag) = token, tag.name == element.name {
                    if tag.isClosing { element.depth -= 1 } else if !tag.isSelfClosing { element.depth += 1 }
                    excluded = element.depth == 0 ? nil : element
                }
                return
            }
            switch token {
            case .opaque: break
            case .text(let text):
                // Unrecognized '<' must stay text when surrounding markup is removed.
                output += text.replacingOccurrences(of: "<", with: "&lt;")
            case .tag(let tag):
                if ["foreignobject", "object", "iframe", "form"].contains(tag.name), !tag.isClosing, !tag.isSelfClosing
                {
                    excluded = (tag.name, 1)
                    return
                }
                if !svgOnly, tag.name == "input", !tag.isClosing, tag.attribute("type") == "checkbox" {
                    output +=
                        tag.attribute("checked") == nil
                        ? "<input type=\"checkbox\" disabled>" : "<input type=\"checkbox\" checked disabled>"
                    return
                }
                guard svgElements.contains(tag.name) || (!svgOnly && elements.contains(tag.name)) else { return }
                if tag.isClosing {
                    output += "</\(tag.name)>"
                    return
                }
                var image: String?
                if tag.name == "img" {
                    image = tag.attribute("src").flatMap(imageSource)
                    guard image != nil else {
                        let alt = tag.attribute("alt") ?? ""
                        output +=
                            alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "<span class=\"preview-missing-image\" aria-hidden=\"true\"></span>" : HTML.escape(alt)
                        return
                    }
                }
                output += "<\(tag.name)"
                if tag.name == "svg" { output += " xmlns=\"http://www.w3.org/2000/svg\"" }
                HTMLScanner.visitAttributes(in: tag.source) { key, raw in
                    let value: String
                    switch key {
                    case "src" where tag.name == "img":
                        guard let src = image else { return true }
                        value = src
                    case "href" where tag.name == "a" && raw.hasPrefix("#"):
                        value = HTMLScanner.decodingEntities(raw)
                    case "style":
                        value = safeStyle(raw)
                        guard !value.isEmpty else { return true }
                    case "fill", "stroke":
                        guard raw.utf8.count <= 64, raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) else {
                            return true
                        }
                        value = raw
                    default:
                        guard attributes.contains(key) else { return true }
                        value = HTMLScanner.decodingEntities(raw)
                    }
                    let name = key == "viewbox" ? "viewBox" : key
                    output += " \(name)=\"\(HTML.escape(value))\""
                    return true
                }
                output += tag.isSelfClosing ? "/>" : ">"
            }
            guard output.utf8.count <= FinderPreview.maximumHTMLBytes else {
                throw FinderPreview.Failure.oversizedReply
            }
        }
        try PreviewConversion.check()
        guard output.utf8.count <= FinderPreview.maximumHTMLBytes else { throw FinderPreview.Failure.oversizedReply }
        return output
    }

    private static func safeStyle(_ raw: String) -> String {
        guard raw.utf8.count <= 2048 else { return "" }
        return raw.split(separator: ";").compactMap { declaration -> String? in
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard styleProperties.contains(name),
                value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " #.%+-".contains($0)) })
            else { return nil }
            return "\(name):\(value)"
        }.joined(separator: ";")
    }
}
