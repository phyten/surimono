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
    private static let hiddenElements: Set<String> = ["rt", "rp", "svg", "math"]

    public static func headings(inHTML html: String) -> [DocumentHeading] {
        scan(html).map(\.heading)
    }

    /// For each of `headings(inHTML:)`, whether it stands right under another heading.
    public static func headingsUnderHeadings(inHTML html: String) -> [Bool] {
        scan(html).map(\.followsHeading)
    }

    private static func scan(_ html: String) -> [(heading: DocumentHeading, followsHeading: Bool)] {
        var headings: [(heading: DocumentHeading, followsHeading: Bool)] = []
        var open: (tag: HTMLScanner.Tag, level: Int, text: String, follows: Bool)?
        var hidden: (name: String, depth: Int)?
        var afterHeading = false
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text):
                if hidden == nil { open?.text += text }
                if open == nil, !text.allSatisfy(\.isWhitespace) { afterHeading = false }
            case .opaque: break
            case .tag(let tag):
                if updateHidden(&hidden, with: tag) { continue }
                if let current = open {
                    guard tag.isClosing, tag.name == current.tag.name else { continue }
                    let text = HTMLScanner.decodingEntities(current.text).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let heading = DocumentHeading(
                            level: current.level, text: text, id: current.tag.attribute("id"))
                        headings.append((heading, current.follows))
                        afterHeading = true
                    }
                    open = nil
                } else if !tag.isClosing, let level = headingLevel(tag.name) {
                    open = (tag, level, "", afterHeading)
                } else if !tag.isClosing {
                    afterHeading = false
                }
            }
        }
        return headings
    }

    /// The entries of the text's own table of contents, which repeat its headings wherever it stands on the pages.
    public static func sourceContentsEntries(inHTML html: String) -> [String] {
        var entries: [String] = []
        var depth = 0
        var link: String?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text): link? += text
            case .opaque: break
            case .tag(let tag):
                if tag.name == "nav" {
                    let isContents = tag.attribute("class")?.split(separator: " ").contains("toc") == true
                    if tag.isClosing, depth > 0 { depth -= 1 } else if depth > 0 || isContents { depth += 1 }
                } else if depth > 0, tag.name == "a" {
                    if tag.isClosing, let text = link {
                        entries.append(
                            HTMLScanner.decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines))
                        link = nil
                    } else if !tag.isClosing {
                        link = ""
                    }
                }
            }
        }
        return entries
    }

    public static func title(ofHTML html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = titlePattern.firstMatch(in: html, range: range),
            let title = Range(match.range(at: 1), in: html)
        else { return nil }
        return plainText(ofHTML: String(html[title])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let titlePattern: NSRegularExpression = {
        guard
            let pattern = try? NSRegularExpression(
                pattern: "<title(?:\\s[^>]*)?>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { preconditionFailure("Invalid title pattern") }
        return pattern
    }()

    private static func headingLevel(_ name: String) -> Int? {
        guard name.count == 2, name.first == "h", let level = name.last?.wholeNumberValue, (1...6).contains(level)
        else { return nil }
        return level
    }

    /// Whether the tag belongs to an element whose text is not read, keeping track of the one being skipped.
    private static func updateHidden(_ hidden: inout (name: String, depth: Int)?, with tag: HTMLScanner.Tag) -> Bool {
        if let current = hidden {
            if tag.name == current.name, !tag.isSelfClosing {
                let depth = current.depth + (tag.isClosing ? -1 : 1)
                hidden = depth == 0 ? nil : (current.name, depth)
            }
            return true
        }
        let isComment = tag.attribute("class")?.split(separator: " ").contains("critic-comment") == true
        guard hiddenElements.contains(tag.name) || isComment, !tag.isClosing, !tag.isSelfClosing else { return false }
        hidden = (tag.name, 1)
        return true
    }

    package static func plainText(ofHTML html: String) -> String {
        var text = ""
        var hidden: (name: String, depth: Int)?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let value):
                if hidden == nil { text += value }
            case .opaque: break
            case .tag(let tag): _ = updateHidden(&hidden, with: tag)
            }
        }
        return HTMLScanner.decodingEntities(text)
    }
}
