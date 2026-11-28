import Foundation

public struct DocumentHeading: Equatable, Sendable {
    public var level: Int
    /// The title shown in contents, bookmarks and the band: what the heading says, without the marks the paper sets
    /// beside it, with a link's words and a formula's source.
    public var text: String
    /// The heading's anchor, when the converter gave it one.
    public var id: String?
    /// The heading as the page prints it, when that differs from `text`: with a footnote's number or a task's keyword,
    /// and `DocumentHeading.formula` where a formula stands, whose glyphs the page's text does not spell reliably.
    public var printed: String?

    /// Stands for a formula in `printed`.
    public static let formula: Character = "\u{FFFC}"

    public init(level: Int, text: String, id: String? = nil, printed: String? = nil) {
        self.level = level
        self.text = text
        self.id = id
        self.printed = printed == text ? nil : printed
    }

    /// What to look for on the page.
    public var printedText: String { printed ?? text }
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

    /// What a heading or a contents entry holds besides its title and the page prints with it: a footnote's mark and a
    /// task's keyword and priority. Contents, bookmarks and the band leave them out, as LaTeX's contents leave out a
    /// heading's footnote.
    private static let printedExtras: Set<String> = ["footnote-ref", "org-todo", "org-done", "org-priority"]
    /// What a heading holds that the paper sets apart from its line: Org's tags, at the end of the line.
    private static let setApartExtras: Set<String> = ["org-tags"]
    /// Elements without a closing tag, which hold no text to leave out.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    /// A section number the paper sets apart from its title by a margin, not by a space.
    private static let sectionNumber = "secnum"

    /// The text of a heading or of a contents entry, read token by token: one rule for every format, so the title a
    /// table of contents shows and the text looked for on the page come from the same reading.
    struct HeadingTextReader {
        private var title = ""
        private var printed = ""
        private var collecting = false
        private var hidden: (name: String, depth: Int)?
        var isHiding: Bool { hidden != nil }
        // An extra being left out, and whether the page prints it on the heading's line. It belongs to the heading:
        // the heading's end ends it too, so an element that is not closed does not take later headings with it.
        private var extra: (name: String, depth: Int, printed: Bool)?
        // The spans still open in a section number, and whether the title after it needs a space.
        private var number: Int?
        private var spaceAfterNumber = false

        mutating func begin() {
            self = Self()
            collecting = true
        }

        /// The title and the printed text, with their character references decoded and the white space around them
        /// trimmed.
        mutating func end() -> (title: String, printed: String) {
            func finished(_ text: String) -> String {
                HTMLScanner.decodingEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let result = (finished(title), finished(printed))
            self = Self()
            return result
        }

        mutating func text(_ text: String) {
            guard collecting, hidden == nil, extra?.printed != false else { return }
            if spaceAfterNumber, let first = HTMLScanner.decodingEntities(text).first, !first.isWhitespace {
                append(" ")
            }
            if !text.isEmpty { spaceAfterNumber = false }
            append(text)
        }

        private mutating func append(_ text: String) {
            printed += text
            if extra == nil { title += text }
        }

        /// Whether the tag belongs to what is not read as the heading's text. A closing tag named `boundary`, which
        /// ends the heading or the entry, also ends an extra left open.
        mutating func tag(_ tag: HTMLScanner.Tag, boundary: String?) -> Bool {
            if let current = hidden {
                if tag.name == current.name, !tag.isSelfClosing {
                    let depth = current.depth + (tag.isClosing ? -1 : 1)
                    hidden = depth == 0 ? nil : (current.name, depth)
                }
                return true
            }
            let isComment = classes(of: tag).contains(where: { $0 == "critic-comment" })
            if hiddenElements.contains(tag.name) || isComment, !tag.isClosing, !tag.isSelfClosing {
                if collecting, extra?.printed != false, !isComment,
                    let label = tag.attribute(tag.name == "math" ? "alttext" : "aria-label"), !label.isEmpty
                {
                    if spaceAfterNumber { append(" ") }
                    spaceAfterNumber = false
                    printed.append(DocumentHeading.formula)
                    if extra == nil { title += label }
                }
                hidden = (tag.name, 1)
                return true
            }
            guard collecting else { return false }
            if let skipping = extra {
                if tag.isClosing, tag.name == boundary {
                    extra = nil
                    return false
                }
                if tag.name == skipping.name, !tag.isSelfClosing {
                    let depth = skipping.depth + (tag.isClosing ? -1 : 1)
                    extra = depth == 0 ? nil : (skipping.name, depth, skipping.printed)
                }
                return true
            }
            if !tag.isClosing, !tag.isSelfClosing, !voidElements.contains(tag.name) {
                let names = classes(of: tag)
                if names.contains(where: { setApartExtras.contains(String($0)) }) {
                    extra = (tag.name, 1, false)
                    return true
                }
                if names.contains(where: { printedExtras.contains(String($0)) }) {
                    extra = (tag.name, 1, true)
                    return true
                }
            }
            if tag.name == "span", !tag.isSelfClosing {
                if let depth = number {
                    number = depth + (tag.isClosing ? -1 : 1)
                    if number == 0 {
                        number = nil
                        spaceAfterNumber = true
                    }
                } else if !tag.isClosing, classes(of: tag).contains(where: { $0 == sectionNumber }) {
                    number = 1
                }
            }
            return false
        }
    }

    private static func scan(_ html: String) -> [(heading: DocumentHeading, followsHeading: Bool)] {
        var headings: [(heading: DocumentHeading, followsHeading: Bool)] = []
        var open: (tag: HTMLScanner.Tag, level: Int, follows: Bool)?
        var reader = HeadingTextReader()
        var afterHeading = false
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let text):
                reader.text(text)
                if open == nil, !text.allSatisfy(\.isWhitespace) { afterHeading = false }
            case .opaque: break
            case .tag(let tag):
                if reader.tag(tag, boundary: open?.tag.name) { continue }
                if let current = open {
                    guard tag.isClosing, tag.name == current.tag.name else { continue }
                    let (title, printed) = reader.end()
                    if !title.isEmpty {
                        let heading = DocumentHeading(
                            level: current.level, text: title, id: current.tag.attribute("id"), printed: printed)
                        headings.append((heading, current.follows))
                        afterHeading = true
                    }
                    open = nil
                } else if !tag.isClosing, let level = headingLevel(tag.name) {
                    open = (tag, level, afterHeading)
                    reader.begin()
                } else if !tag.isClosing {
                    afterHeading = false
                }
            }
        }
        return headings
    }

    /// A heading's HTML as a table of contents shows it: without the marks the page sets beside the title, such as a
    /// footnote's number, and without links, whose words stay. An entry is a link of its own; a link inside it would
    /// break it in two. Ids stay with the heading.
    package static func contentsHTML(ofHeading html: String) -> String {
        guard html.contains("<") else { return html }
        var output = ""
        var skipping: (name: String, depth: Int)?
        HTMLScanner.forEachToken(html) { token in
            switch token {
            case .text(let text), .opaque(let text): if skipping == nil { output += text }
            case .tag(let tag):
                if let current = skipping {
                    if tag.name == current.name, !tag.isSelfClosing {
                        let depth = current.depth + (tag.isClosing ? -1 : 1)
                        skipping = depth == 0 ? nil : (current.name, depth)
                    }
                    return
                }
                if !tag.isClosing, !tag.isSelfClosing, !voidElements.contains(tag.name),
                    classes(of: tag).contains(where: {
                        printedExtras.contains(String($0)) || setApartExtras.contains(String($0))
                    })
                {
                    skipping = (tag.name, 1)
                    return
                }
                if tag.name == "a" { return }
                output += tag.isClosing || tag.attribute("id") == nil ? tag.source : withoutID(tag.source)
            }
        }
        return output
    }

    /// The plain title of a heading's HTML, as `headings(inHTML:)` reads it, for a running head or a bookmark.
    package static func title(ofHeading html: String) -> String {
        var reader = HeadingTextReader()
        reader.begin()
        HTMLScanner.forEachToken(html) { token in
            switch token {
            case .text(let text): reader.text(text)
            case .opaque: break
            case .tag(let tag): _ = reader.tag(tag, boundary: nil)
            }
        }
        return reader.end().title
    }

    private static let idAttribute = try? NSRegularExpression(
        pattern: #"\s+id\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)"#, options: [.caseInsensitive])

    private static func withoutID(_ source: String) -> String {
        guard let idAttribute else { return source }
        return idAttribute.stringByReplacingMatches(
            in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
    }

    /// Link labels in print order, with an empty string between separate tables of contents.
    public static func sourceContentsEntries(inHTML html: String) -> [String] {
        var entries: [String] = []
        visitContentsLinks(in: html, navIndex: nil) { entry, startsTable in
            if startsTable && !entries.isEmpty { entries.append("") }
            entries.append(entry.printedText)
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
        var reader: HeadingTextReader?
        var id: String?
        HTMLScanner.forEachToken(html) { token in
            switch token {
            case .text(let text): reader?.text(text)
            case .opaque: break
            case .tag(let tag):
                if reader?.tag(tag, boundary: "a") == true { return }
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
                            reader = HeadingTextReader()
                            reader?.begin()
                            id = tag.attribute("href").flatMap { $0.first == "#" ? String($0.dropFirst()) : nil }
                        } else if var current = reader {
                            reader = nil
                            let (title, printed) = current.end()
                            if !title.isEmpty {
                                visit(
                                    .init(level: max(1, listLevel), text: title, id: id, printed: printed),
                                    startsTable)
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

    /// The classes of an element, split at ASCII white space as HTML does.
    private static func classes(of tag: HTMLScanner.Tag) -> [Substring] {
        tag.attribute("class")?.split(whereSeparator: { " \t\n\r\u{0C}".contains($0) }) ?? []
    }

    package static func plainText(ofHTML html: String) -> String {
        var text = ""
        // Only the hidden elements are left out: the reader is not collecting.
        var reader = HeadingTextReader()
        for token in HTMLScanner.tokens(html) {
            switch token {
            case .text(let value):
                if !reader.isHiding { text += value }
            case .opaque: break
            case .tag(let tag): _ = reader.tag(tag, boundary: nil)
            }
        }
        return HTMLScanner.decodingEntities(text)
    }
}
