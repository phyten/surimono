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

    /// Link labels in print order, with an empty string between separate tables of contents.
    public static func sourceContentsEntries(inHTML html: String) -> [String] {
        var entries: [String] = []
        visitContentsLinks(in: html, navIndex: nil) { entry, startsTable in
            if startsTable && !entries.isEmpty { entries.append("") }
            entries.append(entry.text)
        }
        return entries
    }

    /// A native list controls its own selection, order, labels and nesting. Its links identify the
    /// corresponding headings even when several headings have the same printed title.
    package static func contentsHeadings(in html: String, navIndex: Int) -> [DocumentHeading] {
        var entries: [DocumentHeading] = []
        visitContentsLinks(in: html, navIndex: navIndex) { entry, _ in entries.append(entry) }
        return entries
    }

    private static func visitContentsLinks(
        in html: String, navIndex: Int?, visit: (DocumentHeading, Bool) -> Void
    ) {
        var nextNav = 0
        var nesting = 0
        var listLevel = 0
        var startsTable = false
        var link: String?
        var id: String?
        HTMLScanner.forEachToken(html) { token in
            switch token {
            case .text(let text): link? += text
            case .opaque: break
            case .tag(let tag):
                if tag.name == "nav" {
                    if tag.isClosing {
                        if nesting > 0 { nesting -= 1 }
                    } else {
                        let selected =
                            navIndex.map { $0 == nextNav }
                            ?? (tag.attribute("class")?.split(separator: " ").contains("toc") == true)
                        nextNav += 1
                        if nesting > 0 || selected {
                            if nesting == 0 {
                                startsTable = true
                                listLevel = 0
                            }
                            nesting += 1
                        }
                    }
                } else if nesting > 0 {
                    switch tag.name {
                    case "ul", "ol": listLevel = max(0, listLevel + (tag.isClosing ? -1 : 1))
                    case "a":
                        if !tag.isClosing {
                            link = ""
                            id = tag.attribute("href").flatMap { $0.first == "#" ? String($0.dropFirst()) : nil }
                        } else if let text = link {
                            link = nil
                            let label = HTMLScanner.decodingEntities(text).trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            if !label.isEmpty {
                                visit(.init(level: max(1, listLevel), text: label, id: id), startsTable)
                                startsTable = false
                            }
                        }
                    default: break
                    }
                }
            }
        }
    }

    /// The text of the first `<title>` element that has a closing tag: the first match of the expression
    /// `<title(?:\s[^>]*)?>(.*?)</title>` (case-insensitive, `.` matching line breaks), found with plain byte searches.
    /// The expression retried its lazy match from every `<title`, which took quadratic time on a page of openers that
    /// never close; Foundation's case-insensitive string search took a second and a half on 27 MB.
    public static func title(ofHTML html: String) -> String? {
        let bytes = Array(html.utf8)
        func lowered(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte | 0x20 : byte }
        /// The offset of `needle` (`<` and then lowercase ASCII) at or after `from`, ignoring ASCII case.
        func find(_ needle: [UInt8], from: Int) -> Int? {
            bytes.withUnsafeBufferPointer { buffer in
                var index = from
                while index <= buffer.count - needle.count {
                    if buffer[index] == UInt8(ascii: "<") {
                        var matched = 1
                        while matched < needle.count, lowered(buffer[index + matched]) == needle[matched] {
                            matched += 1
                        }
                        if matched == needle.count { return index }
                    }
                    index += 1
                }
                return nil
            }
        }
        /// Whether the character at `offset` is `\s` of the expression: ICU's White_Space characters.
        func isSpace(at offset: Int) -> Bool {
            let rest = String(decoding: bytes[offset..<min(bytes.count, offset + 4)], as: UTF8.self)
            return rest.unicodeScalars.first?.properties.isWhitespace == true
        }
        let opener = Array("<title".utf8)
        let closer = Array("</title>".utf8)
        var cursor = 0
        while let start = find(opener, from: cursor) {
            let after = start + opener.count
            cursor = start + 1
            guard after < bytes.count, bytes[after] == UInt8(ascii: ">") || isSpace(at: after) else { continue }
            // Without a `>` or a closing tag after this opener, no later opener has one either.
            guard let end = bytes[after...].firstIndex(of: UInt8(ascii: ">")),
                let close = find(closer, from: end + 1)
            else { return nil }
            return plainText(ofHTML: String(decoding: bytes[(end + 1)..<close], as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

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
