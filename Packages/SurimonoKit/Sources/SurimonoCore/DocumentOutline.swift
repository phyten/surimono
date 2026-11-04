import Foundation

public struct DocumentHeading: Equatable, Sendable {
    public var level: Int
    public var text: String
    /// The heading's anchor, when the converter gave it one.
    public var id: String?

    public init(level: Int, text: String, id: String? = nil) {
        self.level = level
        self.text = text
        self.id = id
    }
}

/// Reads the structure of a document's HTML: the headings for tables of contents and the amount of text.
public enum DocumentOutline {
    public static func headings(inHTML html: String) -> [DocumentHeading] {
        let range = NSRange(html.startIndex..., in: html)
        return headingPattern.matches(in: html, range: range).compactMap { match in
            guard let level = Range(match.range(at: 1), in: html).flatMap({ Int(html[$0]) }),
                let attributes = Range(match.range(at: 2), in: html),
                let body = Range(match.range(at: 3), in: html)
            else { return nil }
            let text = plainText(ofHTML: String(html[body])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return DocumentHeading(level: level, text: text, id: anchor(in: String(html[attributes])))
        }
    }

    /// The zero-based page each heading stands on, in order. Pages are searched forward only, so a heading quoted in
    /// the text before it does not count, and a heading that cannot be found leaves the next one to search from the
    /// same page.
    public static func pages(of headings: [DocumentHeading], inPageTexts pages: [String]) -> [Int?] {
        let lines = pages.map { $0.components(separatedBy: .newlines).map(normalized).filter { !$0.isEmpty } }
        var cursor = 0
        return headings.map { heading in
            let target = normalized(heading.text)
            guard !target.isEmpty, cursor < lines.count else { return nil }
            for page in cursor..<lines.count where contains(target, in: lines[page]) {
                cursor = page
                return page
            }
            return nil
        }
    }

    private static let headingPattern: NSRegularExpression = {
        // The pattern is a constant, so failing here is a programming error caught by the first test.
        guard
            let pattern = try? NSRegularExpression(
                pattern: "<h([1-6])((?:\\s[^>]*)?)>(.*?)</h\\1>",
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { preconditionFailure("Invalid heading pattern") }
        return pattern
    }()

    private static func anchor(in attributes: String) -> String? {
        guard let start = attributes.range(of: "id=\"") else { return nil }
        let rest = attributes[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// A heading can wrap over several lines, and a theme can number it, which puts text in front of it.
    private static func contains(_ target: String, in lines: [String]) -> Bool {
        for start in lines.indices {
            if lines[start].hasSuffix(target) { return true }
            var joined = ""
            for line in lines[start...] {
                joined += line
                if joined == target || joined.hasSuffix(target) { return true }
                guard joined.count < target.count + 16 else { break }
            }
        }
        return false
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    static func plainText(ofHTML html: String) -> String {
        var text = html
        for pattern in ["<rt[^>]*>.*?</rt>", "<rp[^>]*>.*?</rp>", "<style[^>]*>.*?</style>", "<svg[^>]*>.*?</svg>"] {
            text = text.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&amp;": "&"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }
}

/// What the reader may want to know before printing: an amount of text that also makes sense for Japanese.
public struct DocumentStatistics: Equatable, Sendable {
    /// Characters of text, without white space.
    public var characters: Int

    /// Silent reading of Japanese is commonly put at around 500 characters a minute.
    public var readingMinutes: Int { characters == 0 ? 0 : max(1, Int((Double(characters) / 500).rounded())) }

    public init(characters: Int) { self.characters = characters }

    public init(html: String) {
        characters = DocumentOutline.plainText(ofHTML: html).unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
        }
    }
}
