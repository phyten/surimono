import Foundation

/// Rebuilds saved HTML using inert paper elements. In particular CSS cannot escape an output and restyle the notebook.
enum NotebookHTML {
    private static let allowed: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "code", "col", "colgroup", "dd", "del", "details",
        "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i",
        "img", "li", "mark", "ol", "p", "pre", "s", "small", "span", "strong", "sub", "summary", "sup",
        "table", "tbody", "td", "th", "thead", "tfoot", "tr", "u", "ul",
    ]
    private static let blocked: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "canvas", "audio", "video",
    ]

    static func clean(_ html: String) -> (html: String, hasContent: Bool, removedContent: Bool) {
        var result = ""
        var skip: String?
        var depth = 0
        var content = false
        var removed = false
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text):
                if skip == nil {
                    result += text
                    if !HTMLScanner.decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        content = true
                    }
                }
            case .opaque: break
            case .tag(let tag):
                if let skipping = skip {
                    if tag.name == skipping {
                        if tag.isClosing { depth -= 1 } else if !tag.isSelfClosing { depth += 1 }
                        if depth == 0 { skip = nil }
                    }
                    continue
                }
                if blocked.contains(tag.name) {
                    if tag.name != "script" && tag.name != "style" { removed = true }
                    if !tag.isClosing, !tag.isSelfClosing, tag.name != "embed" {
                        skip = tag.name
                        depth = 1
                    }
                    continue
                }
                guard allowed.contains(tag.name) else { continue }
                if tag.isClosing {
                    result += "</\(tag.name)>"
                    continue
                }
                var attributes = ""
                for name in [
                    "class", "title", "alt", "colspan", "rowspan", "scope", "start", "open", "width", "height", "href",
                    "src",
                ] {
                    guard let value = tag.attribute(name) else { continue }
                    if ["src", "href"].contains(name), !safeURL(value, image: name == "src") { continue }
                    attributes += " \(name)=\"\(HTML.escape(value))\""
                }
                // A classed pre is an output, not source code eligible for line numbers and a language badge.
                if tag.name == "pre", tag.attribute("class") == nil { attributes += " class=\"notebook-output\"" }
                result += "<\(tag.name)\(attributes)>"
                if tag.name == "img", tag.attribute("src").map({ safeURL($0, image: true) }) == true { content = true }
            }
        }
        return (result, content, removed)
    }

    private static func safeURL(_ source: String, image: Bool) -> Bool {
        let value = source.unicodeScalars.filter { $0.value > 32 }.map(String.init).joined().lowercased()
        if value.hasPrefix("data:") {
            return image && NotebookImage.mimeTypes.contains { value.hasPrefix("data:\($0);") }
        }
        guard let colon = value.firstIndex(of: ":") else { return true }
        return ["https", "http", "file", "mailto"].contains(String(value[..<colon]))
    }

    static func setting(_ name: String, value: String, in tag: String) -> String {
        // The scanner has already isolated this tag; quoted values may contain '>' or the other quote character.
        let pattern = "(?i)(\\s" + name + #"\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
            let range = Range(match.range, in: tag)
        else { return tag }
        var result = tag
        result.replaceSubrange(range, with: " \(name)=\"\(HTML.escape(value))\"")
        return result
    }
}
