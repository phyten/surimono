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

/// One line of a table of contents; a heading that was not found on any page has no page to go to.
public struct OutlineEntry: Equatable, Sendable {
    public var level: Int
    public var title: String
    public var pageIndex: Int?

    public init(level: Int, title: String, pageIndex: Int?) {
        self.level = level
        self.title = title
        self.pageIndex = pageIndex
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

    /// The zero-based page each heading stands on, in order. A heading stands on lines of its own, wrapped or with a
    /// number in front of it, so the same words in a sentence do not count. The search only moves forward, past each
    /// heading it found. The lines are indexed by their text, so a heading that cannot be found costs one lookup. The
    /// lines of `contentsEntries`, where the text lists its headings itself, are not taken for them.
    public static func pages(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = []
    ) -> [Int?] {
        var index = LineIndex(pages: pages)
        index.exclude(contentsEntries.map(normalized))
        var cursor = 0
        return headings.map { heading in
            let target = normalized(heading.text)
            guard !target.isEmpty, let match = index.firstMatch(of: target, from: cursor) else { return nil }
            cursor = match.end
            return match.page
        }
    }

    private struct LineIndex {
        /// A heading wraps only when it is long, so a wrapped one shares at least this much with its first line.
        private static let wrappedPrefixLength = 4

        private var lines: [(page: Int, forms: [String])] = []
        private var whole: [String: [Int]] = [:]
        private var wrapped: [String: [Int]] = [:]
        private var excluded: Set<Int> = []

        init(pages: [String]) {
            for (page, text) in pages.enumerated() {
                for line in text.components(separatedBy: .newlines) {
                    let forms = Self.forms(of: line)
                    guard let first = forms.first, !first.isEmpty else { continue }
                    for form in forms {
                        whole[form, default: []].append(lines.count)
                        if form.count >= Self.wrappedPrefixLength {
                            wrapped[String(form.prefix(Self.wrappedPrefixLength)), default: []].append(lines.count)
                        }
                    }
                    lines.append((page, forms))
                }
            }
        }

        mutating func exclude(_ entries: [String]) {
            var position = 0
            for entry in entries where !entry.isEmpty {
                guard let line = Self.first(in: whole[entry] ?? [], atLeast: position) else { continue }
                excluded.insert(line)
                position = line + 1
            }
        }

        func firstMatch(of target: String, from cursor: Int) -> (page: Int, end: Int)? {
            var best: (page: Int, end: Int, start: Int)?
            let exact = whole[target] ?? []
            var start = Self.firstPosition(in: exact, atLeast: cursor)
            while start < exact.count, excluded.contains(exact[start]) { start += 1 }
            if start < exact.count {
                best = (lines[exact[start]].page, exact[start] + 1, exact[start])
            }
            guard target.count > Self.wrappedPrefixLength else { return best.map { ($0.page, $0.end) } }
            let candidates = wrapped[String(target.prefix(Self.wrappedPrefixLength))] ?? []
            var position = Self.firstPosition(in: candidates, atLeast: cursor)
            while position < candidates.count, candidates[position] < best?.start ?? .max {
                let start = candidates[position]
                if let end = endOfWrappedHeading(target, from: start) {
                    best = (lines[start].page, end, start)
                    break
                }
                position += 1
            }
            return best.map { ($0.page, $0.end) }
        }

        /// The index after the last line of a heading that wraps from `start`. It stays on one page.
        private func endOfWrappedHeading(_ target: String, from start: Int) -> Int? {
            for form in lines[start].forms where target.hasPrefix(form) {
                var joined = form
                var index = start + 1
                while index < lines.count, lines[index].page == lines[start].page {
                    joined += lines[index].forms[0]
                    index += 1
                    if joined == target { return index }
                    guard target.hasPrefix(joined) else { break }
                }
            }
            return nil
        }

        /// The line as it stands, and without a number when it has one: a theme can number a heading with a counter,
        /// which puts text in front of it on the page only.
        private static func forms(of line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let number = trimmed.prefix { $0.isNumber || ".．、:：-)）(（".contains($0) }
            let rest = trimmed.dropFirst(number.count)
            let endsNumber = rest.first?.isWhitespace == true || number.last.map { !$0.isNumber } == true
            guard !number.isEmpty, !rest.isEmpty, endsNumber else { return [normalized(line)] }
            return [normalized(line), normalized(String(rest))]
        }

        private static func first(in sorted: [Int], atLeast value: Int) -> Int? {
            let position = firstPosition(in: sorted, atLeast: value)
            return position < sorted.count ? sorted[position] : nil
        }

        private static func firstPosition(in sorted: [Int], atLeast value: Int) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    /// The level of the chapters: the largest headings, unless the largest is a single title over everything else.
    public static func chapterLevel(of levels: [Int]) -> Int? {
        guard let top = levels.min() else { return nil }
        guard levels.filter({ $0 == top }).count == 1, let next = levels.filter({ $0 > top }).min() else { return top }
        return next
    }

    /// The pages that end a chapter. A chapter that opens a page leaves the page before it as the end of the one
    /// before; one that starts halfway down a page shares that page with it.
    public static func chapterEnds(of headings: [DocumentHeading], pages: [Int?], inPageTexts texts: [String]) -> Set<
        Int
    > {
        var opening: [Int: Bool] = [:]
        let levels = headings.enumerated().map { index, heading -> (level: Int, page: Int?) in
            if pages.indices.contains(index), let page = pages[index], texts.indices.contains(page) {
                opening[index] = opens(texts[page], with: heading)
            }
            return (heading.level, pages.indices.contains(index) ? pages[index] : nil)
        }
        return chapterEnds(of: levels) { opening[$0] ?? true }
    }

    /// The pages that end a chapter of a PDF, from its bookmarks, which point at the page a chapter opens.
    public static func chapterEnds(of entries: [OutlineEntry]) -> Set<Int> {
        chapterEnds(of: entries.map { ($0.level, $0.pageIndex) }) { _ in true }
    }

    private static func chapterEnds(of headings: [(level: Int, page: Int?)], opensPage: (Int) -> Bool) -> Set<Int> {
        guard let level = chapterLevel(of: headings.map(\.level)) else { return [] }
        let chapters = headings.indices.filter { headings[$0].level == level }
        var ends: Set<Int> = []
        for index in chapters.dropFirst() {
            guard let page = headings[index].page else { continue }
            let end = opensPage(index) ? page - 1 : page
            if end >= 0 { ends.insert(end) }
        }
        return ends
    }

    /// Whether a heading stands first on a page. A theme can put a number in front of it, so the line only has to
    /// hold the heading; a long heading wraps, so it may also go on past the line.
    private static func opens(_ text: String, with heading: DocumentHeading) -> Bool {
        let target = normalized(heading.text)
        let lines = text.components(separatedBy: .newlines).lazy.map(normalized)
        guard !target.isEmpty, let first = lines.first(where: { !$0.isEmpty }) else { return false }
        return first.contains(target) || target.hasPrefix(first)
    }

    public static func entries(of headings: [DocumentHeading], inPageTexts pages: [String]) -> [OutlineEntry] {
        zip(headings, self.pages(of: headings, inPageTexts: pages)).map { heading, page in
            OutlineEntry(level: heading.level, title: heading.text, pageIndex: page)
        }
    }

    /// The entry the reader is in on `page`: the last one that started by then.
    public static func currentEntry(in entries: [OutlineEntry], page: Int) -> Int? {
        entries.lastIndex { entry in entry.pageIndex.map { $0 <= page } ?? false }
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
        guard hiddenElements.contains(tag.name), !tag.isClosing, !tag.isSelfClosing else { return false }
        hidden = (tag.name, 1)
        return true
    }

    /// Only letters and digits take part: a PDF's text can come back with its own ligatures and widths, and WebKit's
    /// PDF returns an em dash as a combining stroke, which `CharacterSet.alphanumerics` would keep.
    private static func normalized(_ text: String) -> String {
        String(
            text.precomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                .map(Character.init))
    }

    static func plainText(ofHTML html: String) -> String {
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

/// What the tray tells about a text: its headings, its amount of text, and its own page breaks.
public struct DocumentFacts: Equatable, Sendable {
    public var title: String?
    public var headings: [DocumentHeading]
    public var statistics: DocumentStatistics
    /// How often each page break syntax stands in the text.
    public var pageBreakCounts: [PageBreakSyntax: Int]
    public var thematicBreakCount: Int
    public var hasSourceContents: Bool

    public init(fragment: HTMLFragment) {
        title = fragment.title
        headings = DocumentOutline.headings(inHTML: fragment.body)
        statistics = DocumentStatistics(html: fragment.body)
        var counts: [PageBreakSyntax: Int] = [:]
        for syntax in PageBreakSyntax.allCases {
            let count = fragment.body.components(separatedBy: "data-syntax=\"\(syntax.rawValue)\"").count - 1
            if count > 0 { counts[syntax] = count }
        }
        pageBreakCounts = counts
        thematicBreakCount = fragment.body.components(separatedBy: "<hr").count - 1
        hasSourceContents = fragment.body.contains("<nav class=\"toc\"")
    }
}

/// What the reader may want to know before printing: an amount of text that also makes sense for Japanese.
public struct DocumentStatistics: Equatable, Sendable {
    /// Characters of text, without white space.
    public var characters: Int

    /// Silent reading of Japanese is commonly put at around 500 characters a minute.
    public var readingMinutes: Int { characters == 0 ? 0 : max(1, Int((Double(characters) / 500).rounded())) }

    public init(characters: Int) { self.characters = characters }

    /// Two pages to a sheet.
    public static func duplexSheets(pageCount: Int) -> Int { (pageCount + 1) / 2 }

    public init(html: String) {
        characters = DocumentOutline.plainText(ofHTML: html).unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
        }
    }
}
