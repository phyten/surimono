import Foundation

/// Printed destinations for links in converted text. The original markup remains untouched.
public enum PaperLinks: String, Codable, CaseIterable, Sendable {
    case asIs, endnotes, inline

    public func apply(to html: String, language: String = "en") -> String {
        guard self != .asIs else { return html }
        // Headings stay as written: the outline finds each one on the page by its exact text, so added characters
        // would lose its page for the contents, the chapter in the header and the right-page starts.
        let excluded: Set<String> = [
            "pre", "code", "svg", "math", "script", "style", "textarea", "title", "h1", "h2", "h3", "h4", "h5", "h6",
        ]
        let excludedClasses: Set<String> = ["toc", "paper-toc", "footnote-ref", "paper-links"]
        let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track",
            "wbr",
        ]
        var stack: [(name: String, excluded: Bool)] = []
        var anchor: (url: String, text: String, excluded: Bool)?
        var urls: [String] = []
        var numbers: [String: Int] = [:]
        var output = ""
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .opaque(let source): output += source
            case .text(let text):
                output += text
                if anchor != nil { anchor?.text += HTMLScanner.decodingEntities(text) }
            case .tag(let tag):
                output += tag.source
                if tag.isClosing {
                    if tag.name == "a", let current = anchor {
                        anchor = nil
                        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let url = current.url
                        let scheme = url.lowercased()
                        let withoutScheme = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
                        if !current.excluded, !text.isEmpty,
                            ["http://", "https://", "mailto:"].contains(where: scheme.hasPrefix),
                            text != url, text != withoutScheme,
                            !(scheme.hasPrefix("mailto:") && text == String(url.dropFirst(7)))
                        {
                            if self == .inline {
                                output += "<span class=\"paper-link-url\"> (\(HTML.escape(url)))</span>"
                            } else {
                                let number: Int
                                if let existing = numbers[url] {
                                    number = existing
                                } else {
                                    urls.append(url)
                                    number = urls.count
                                    numbers[url] = number
                                }
                                output += "<sup class=\"paper-link-ref\">[\(number)]</sup>"
                            }
                        }
                    }
                    if let index = stack.lastIndex(where: { $0.name == tag.name }) { stack.removeSubrange(index...) }
                } else {
                    let classes = Set(
                        (tag.attribute("class") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                    let blocked =
                        stack.last?.excluded == true || excluded.contains(tag.name)
                        || !classes.isDisjoint(with: excludedClasses)
                        || tag.attribute("role") == "doc-noteref" || tag.attribute("role") == "doc-toc"
                    if tag.name == "a" {
                        anchor = (tag.attribute("href") ?? "", "", blocked)
                    } else if blocked, anchor != nil {
                        anchor?.excluded = true
                    }
                    if !tag.isSelfClosing, !voidElements.contains(tag.name) { stack.append((tag.name, blocked)) }
                }
            }
        }
        guard !urls.isEmpty else { return output }
        let rows = urls.enumerated().map { "<li><span>[\($0.offset + 1)]</span> \(HTML.escape($0.element))</li>" }
            .joined()
        return output
            + "\n<section class=\"paper-links\"><h2>\(HTML.escape(Self.title(language: language)))</h2><ol>\(rows)</ol></section>"
    }

    public static func title(language: String) -> String {
        UILanguage.name(
            [
                "en": "Links", "ja": "リンク", "zh-Hans": "链接", "zh-Hant": "連結", "ko": "링크",
                "fr": "Liens", "de": "Links", "es": "Enlaces",
            ], language: language, english: "Links")
    }
}
