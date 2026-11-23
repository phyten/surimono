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

    /// Everything printed between the preceding contents block (or document start) and this block's
    /// first link, including its caption. This locates even a titleless local table after ordinary prose.
    public struct SourceContents: Equatable, Sendable {
        public var precedingText: String
        public var entries: [String]
        public var caption: String
        public var previousBlock: String
        public var followingBlock: String
    }

    public static func sourceContents(inHTML html: String) -> [SourceContents] {
        guard html.contains("<nav") || html.range(of: "<nav", options: .caseInsensitive) != nil else { return [] }
        var blocks: [SourceContents] = []
        var preceding = ""
        var entries: [String] = []
        var caption = ""
        var bodyBlock = ""
        var previous = ""
        var needsFollowing = false
        func finishBodyBlock() {
            let text = bodyBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyBlock = ""
            guard !text.isEmpty else { return }
            previous = HTMLScanner.decodingEntities(text)
            if needsFollowing {
                blocks[blocks.count - 1].followingBlock = previous
                needsFollowing = false
            }
        }
        var depth = 0
        var hidden: (name: String, depth: Int)?
        var link: String?
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text):
                guard hidden == nil else { continue }
                if link != nil {
                    link? += text
                } else if depth == 0 {
                    preceding += text
                    bodyBlock += text
                } else if entries.isEmpty {
                    caption += text
                    preceding += text
                }
            case .opaque: break
            case .tag(let tag):
                if updateHidden(&hidden, with: tag) { continue }
                if depth == 0, bodyBoundaries.contains(tag.name) { finishBodyBlock() }
                if tag.name == "nav" {
                    if tag.isClosing, depth > 0 {
                        depth -= 1
                        if depth == 0, !entries.isEmpty {
                            blocks.append(
                                SourceContents(
                                    precedingText: HTMLScanner.decodingEntities(preceding), entries: entries,
                                    caption: HTMLScanner.decodingEntities(caption), previousBlock: previous,
                                    followingBlock: "")
                            )
                            preceding = ""
                            entries = []
                            previous = ""
                            needsFollowing = true
                        }
                    } else if !tag.isClosing,
                        depth > 0 || tag.attribute("class")?.split(separator: " ").contains("toc") == true
                    {
                        if depth == 0 {
                            caption = ""
                            needsFollowing = false
                        }
                        depth += 1
                    }
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
        finishBodyBlock()
        return blocks
    }

    // Inline spans may split a printed word, so only block boundaries finish a neighbouring text anchor.
    private static let bodyBoundaries: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "li", "td", "th", "dt", "dd", "div", "section",
        "blockquote", "figure", "figcaption", "header", "footer", "nav", "br", "hr",
    ]

    /// A flat list for callers interested only in labels.
    public static func sourceContentsEntries(inHTML html: String) -> [String] {
        Array(sourceContents(inHTML: html).map(\.entries).joined(separator: [""]))
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
