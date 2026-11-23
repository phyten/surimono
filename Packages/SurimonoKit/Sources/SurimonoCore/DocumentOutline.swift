import Foundation

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

extension DocumentOutline {
    /// The zero-based page each heading stands on, in order. A heading stands on lines of its own, wrapped or with a
    /// number in front of it, so the same words in a sentence do not count. The search only moves forward, past each
    /// heading it found. The lines are indexed by their text, so a heading that cannot be found costs one lookup. The
    /// lines of `contentsEntries`, where the text lists its headings itself, are not taken for them.
    public static func pages(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = []
    ) -> [Int?] {
        guard !headings.isEmpty else { return [] }
        var labels = Labels()
        let titles = headings.map { labels.insert(normalized($0.text)) }
        let tables = contentsEntries.split(separator: "").map { table in
            var entries: [Int] = []
            for entry in table {
                let text = normalized(entry)
                if !text.isEmpty { entries.append(labels.insert(text, following: !entries.isEmpty)) }
            }
            return entries
        }
        let index = LineIndex(pages: pages, labels: labels)
        let excluded = index.contentsLines(tables)
        var matches = index.headingMatches(excluding: excluded)
        var cursor = 0
        return titles.map { id in
            while let first = matches[id]?.last, first.lowerBound < cursor { matches[id]?.removeLast() }
            guard let match = matches[id]?.popLast() else { return nil }
            cursor = match.upperBound
            return index.lines[match.lowerBound].page
        }
    }

    /// Each complete spelling has one integer ID, including labels shared by several tables. A prefix also
    /// tells whether another printed line could complete a wrapped label.
    private struct Labels {
        struct Prefix {
            var next: [Character: Int] = [:]
            var complete = false
            var allowsShortWrap = false
        }
        var prefixes = [Prefix()]

        mutating func insert(_ text: String, following: Bool = false) -> Int {
            var node = 0
            for character in text {
                if let next = prefixes[node].next[character] {
                    node = next
                } else {
                    let next = prefixes.count
                    prefixes[node].next[character] = next
                    prefixes.append(Prefix())
                    node = next
                }
                if following { prefixes[node].allowsShortWrap = true }
            }
            prefixes[node].complete = node != 0
            return node
        }

        func advance(_ node: Int, by text: String) -> Int? {
            var node = node
            for character in text {
                guard let next = prefixes[node].next[character] else { return nil }
                node = next
            }
            return node
        }
    }

    private struct LineIndex {
        struct Line {
            let page: Int
            var ends: [Int: Int] = [:]
            var shortWraps: [Int: Int] = [:]
        }
        var lines: [Line] = []

        private typealias Spelling = (node: Int, short: Bool)

        init(pages: [String], labels: Labels) {
            for (page, text) in pages.enumerated() {
                var previous: [Spelling] = []
                var continued: [Spelling] = []
                var start = 0
                for raw in text.components(separatedBy: .newlines) {
                    let forms = Self.forms(of: raw)
                    guard !forms[0].isEmpty else { continue }
                    let line = lines.count
                    lines.append(Line(page: page))
                    // Check the adjacent pair even while a longer spelling is open. A failed wrap can end
                    // on the first line of the next real heading.
                    continued = extend(continued, from: start, by: forms[0], labels: labels)
                    let pair = extend(previous, from: line - 1, by: forms[0], labels: labels)
                    if continued.isEmpty {
                        start = line - 1
                        continued = pair
                    }
                    previous.removeAll(keepingCapacity: true)
                    for form in forms where !form.isEmpty {
                        guard let node = labels.advance(0, by: form) else { continue }
                        let prefix = labels.prefixes[node]
                        if prefix.complete { lines[line].ends[node] = line + 1 }
                        // The preceding items fix the start of an interior entry, even with a short first line.
                        let short = form.count < 4
                        if !prefix.next.isEmpty && (!short || prefix.allowsShortWrap) {
                            previous.append((node, short))
                        }
                    }
                }
            }
        }

        private mutating func extend(_ spellings: [Spelling], from start: Int, by text: String, labels: Labels)
            -> [Spelling]
        {
            var longer: [Spelling] = []
            for spelling in spellings {
                guard let node = labels.advance(spelling.node, by: text) else { continue }
                let prefix = labels.prefixes[node]
                if prefix.complete {
                    if spelling.short {
                        lines[start].shortWraps[node] = lines.count
                    } else {
                        lines[start].ends[node] = lines.count
                    }
                }
                if !prefix.next.isEmpty { longer.append((node, spelling.short)) }
            }
            return longer
        }

        /// Each table is the first complete run after the preceding one. Keeping the length of the matching
        /// suffix lets a partial run such as A A A still lead into A A B without rewinding the PDF cursor.
        func contentsLines(_ tables: [[Int]]) -> Set<Int> {
            var excluded: Set<Int> = []
            var line = 0
            for entries in tables {
                guard !entries.isEmpty else { continue }
                let fallback = Self.prefixLengths(entries)
                var starts: [Int] = []
                var matched = 0
                while line < lines.count {
                    let id = entries[matched]
                    let end = lines[line].ends[id] ?? (matched > 0 ? lines[line].shortWraps[id] : nil)
                    if let end {
                        starts.append(line)
                        line = end
                        matched += 1
                        if matched == entries.count {
                            excluded.formUnion(starts[starts.count - matched]..<end)
                            break
                        }
                    } else if matched > 0 {
                        matched = fallback[matched - 1]
                    } else {
                        line += 1
                    }
                }
                if line == lines.count { break }
            }
            return excluded
        }

        private static func prefixLengths(_ entries: [Int]) -> [Int] {
            var lengths = Array(repeating: 0, count: entries.count)
            var matched = 0
            for index in entries.indices.dropFirst() {
                while matched > 0 && entries[matched] != entries[index] { matched = lengths[matched - 1] }
                if entries[matched] == entries[index] { matched += 1 }
                lengths[index] = matched
            }
            return lengths
        }

        /// Index body matches only. A wrapped heading cannot continue through the start of a table.
        func headingMatches(excluding excluded: Set<Int>) -> [Int: [Range<Int>]] {
            var matches: [Int: [Range<Int>]] = [:]
            var nextExcluded = lines.count
            for line in lines.indices.reversed() {
                if excluded.contains(line) {
                    nextExcluded = line
                } else {
                    for (id, end) in lines[line].ends where end <= nextExcluded {
                        matches[id, default: []].append(line..<end)
                    }
                }
            }
            return matches
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

    public static func entries(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = []
    ) -> [OutlineEntry] {
        zip(headings, self.pages(of: headings, inPageTexts: pages, contentsEntries: contentsEntries)).map {
            heading, page in
            OutlineEntry(level: heading.level, title: heading.text, pageIndex: page)
        }
    }

    /// The entry the reader is in on `page`: the last one that started by then.
    public static func currentEntry(in entries: [OutlineEntry], page: Int) -> Int? {
        entries.lastIndex { entry in entry.pageIndex.map { $0 <= page } ?? false }
    }

    public static func currentChapter(in entries: [OutlineEntry], page: Int) -> Int? {
        guard let level = chapterLevel(of: entries.map(\.level)) else { return nil }
        return entries.lastIndex { entry in
            entry.level == level && (entry.pageIndex.map { $0 <= page } ?? false)
        }
    }

    /// Only letters and digits take part: a PDF's text can come back with its own ligatures and widths, and WebKit's
    /// PDF returns an em dash as a combining stroke, which `CharacterSet.alphanumerics` would keep.
    private static func normalized(_ text: String) -> String {
        String(
            text.precomposedStringWithCompatibilityMapping.unicodeScalars
                .filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                .map(Character.init))
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
    public var offersLaTeXComposition = false
    public var latexRecognition: LaTeXRecognition?
    /// The language a source file was told to be from its decoded text, by the conversion that drew it.
    public var sourceLanguage: SourceLanguage?
    public var beamerPageSize: CGSize?
    public var unsupportedBeamerTheme: String?
    public var unreadableBeamerFrames = 0
    public var continuedBeamerFrames = 0
    /// Source frame numbers survive both overlay expansion and measured page continuation.
    public var beamerPageFrames: [Int] = []
    private var beamerSectionFrames: [Int] = []
    public var beamerOutline: [OutlineEntry]? {
        guard beamerPageSize != nil else { return nil }
        var page = 0
        return zip(headings, beamerSectionFrames).map { heading, frame in
            // A mode can omit the first frame of a section. Its anchor moves to the next printed frame.
            while page < beamerPageFrames.count, beamerPageFrames[page] < frame { page += 1 }
            return OutlineEntry(
                level: heading.level, title: heading.text, pageIndex: page < beamerPageFrames.count ? page : nil)
        }
    }
    public var hasSourceContents: Bool

    public init(fragment: HTMLFragment) {
        offersLaTeXComposition = fragment.latexClass?.offersCompositionChoice == true
        latexRecognition = fragment.latexClass?.recognition
        sourceLanguage = fragment.sourceLanguage
        title = fragment.title
        beamerPageSize = fragment.latexClass?.beamerPageSize
        unsupportedBeamerTheme = fragment.latexClass?.unsupportedBeamerTheme
        unreadableBeamerFrames = fragment.latexClass?.unreadableBeamerFrames ?? 0
        if let info = fragment.latexClass, info.beamerPageSize != nil {
            headings = info.beamerSections.map { DocumentHeading(level: $0.level, text: $0.title, id: $0.id) }
            beamerSectionFrames = info.beamerSections.map(\.firstFrame)
        } else {
            headings = DocumentOutline.headings(inHTML: fragment.body)
        }
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
