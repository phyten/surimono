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
    ///
    /// A style can set a heading in capitals or small capitals, and the page's text then holds "I. INTRODUCTION" for
    /// the heading "Introduction". Only a heading the spelling as written does not find is looked for without case,
    /// and only between the headings found before and after it, so a line that differs from a heading only in case
    /// does not take the place of the heading found as written.
    public static func pages(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = []
    ) -> [Int?] {
        guard !headings.isEmpty else { return [] }
        let written = Matching(headings: headings, pages: pages, contentsEntries: contentsEntries, foldsCase: false)
        var found = written.forward()
        if found.contains(nil) {
            let folded = Matching(headings: headings, pages: pages, contentsEntries: contentsEntries, foldsCase: true)
            // Both spellings read the same lines; the check only guards the line numbers they share.
            if folded.index.lines.count == written.index.lines.count { folded.fill(&found) }
        }
        return found.map { $0.map { written.index.lines[$0.lowerBound].page } }
    }

    /// The headings' spellings looked for in the lines of the pages, with or without case.
    private struct Matching {
        let titles: [Int]
        let index: LineIndex
        let matches: [Int: [Range<Int>]]

        init(headings: [DocumentHeading], pages: [String], contentsEntries: [String], foldsCase: Bool) {
            var labels = Labels()
            titles = headings.map { labels.insert(normalized($0.text, foldsCase: foldsCase)) }
            let tables = contentsEntries.split(separator: "").map {
                $0.map { normalized($0, foldsCase: foldsCase) }.filter { !$0.isEmpty }
            }
            for table in tables {
                for entry in table { _ = labels.insert(entry) }
            }
            index = LineIndex(pages: pages, labels: labels, foldsCase: foldsCase)
            var excluded: Set<Int> = []
            if !tables.isEmpty {
                let contents = ContentsIndex(lines: index.lines, labels: labels)
                var cursor = 0
                for table in tables where !table.isEmpty {
                    // An unsuccessful search has reached EOF; later tables share the same forward cursor.
                    guard let run = contents.firstRun(of: table, from: cursor) else { break }
                    excluded.formUnion(run)
                    cursor = run.upperBound
                }
            }
            matches = index.headingMatches(excluding: excluded)
        }

        /// The lines of each heading, each found after the one before it.
        func forward() -> [Range<Int>?] {
            var matches = matches
            var cursor = 0
            return titles.map { id in
                while let first = matches[id]?.last, first.lowerBound < cursor { matches[id]?.removeLast() }
                guard let match = matches[id]?.popLast() else { return nil }
                cursor = match.upperBound
                return match
            }
        }

        /// Fills the headings not found with lines between the headings found around them.
        func fill(_ found: inout [Range<Int>?]) {
            var upper = Array(repeating: index.lines.count, count: found.count)
            for i in found.indices.dropLast().reversed() { upper[i] = found[i + 1]?.lowerBound ?? upper[i + 1] }
            var lower = 0
            for i in found.indices {
                if let match = found[i] {
                    lower = match.upperBound
                    continue
                }
                // The matches run from the last line to the first, so this is the first one at or after `lower`.
                guard let match = matches[titles[i]]?.last(where: { $0.lowerBound >= lower }),
                    match.upperBound <= upper[i]
                else { continue }
                found[i] = match
                lower = match.upperBound
            }
        }
    }

    /// Each complete spelling has one integer ID, including labels shared by several tables. A prefix also
    /// tells whether another printed line could complete a wrapped label.
    private struct Labels {
        struct Prefix {
            var next: [Character: Int] = [:]
            var complete = false
        }
        var prefixes = [Prefix()]

        mutating func insert(_ text: String) -> Int {
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
            let forms: [String]
        }
        var lines: [Line] = []

        init(pages: [String], labels: Labels, foldsCase: Bool) {
            for (page, text) in pages.enumerated() {
                var previous: [Int] = []
                var continued: [Int] = []
                var start = 0
                for raw in text.components(separatedBy: .newlines) {
                    let forms = Self.forms(of: raw, foldsCase: foldsCase)
                    guard !forms[0].isEmpty else { continue }
                    let line = lines.count
                    lines.append(Line(page: page, forms: forms))
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
                        if !prefix.next.isEmpty && form.count >= 4 { previous.append(node) }
                    }
                }
            }
        }

        private mutating func extend(_ spellings: [Int], from start: Int, by text: String, labels: Labels)
            -> [Int]
        {
            var longer: [Int] = []
            for spelling in spellings {
                guard let node = labels.advance(spelling, by: text) else { continue }
                let prefix = labels.prefixes[node]
                if prefix.complete { lines[start].ends[node] = lines.count }
                if !prefix.next.isEmpty { longer.append(node) }
            }
            return longer
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
        private static func forms(of line: String, foldsCase: Bool) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let number = trimmed.prefix { $0.isNumber || ".．、:：-)）(（".contains($0) }
            let rest = trimmed.dropFirst(number.count)
            let endsNumber = rest.first?.isWhitespace == true || number.last.map { !$0.isNumber } == true
            guard !number.isEmpty, !rest.isEmpty, endsNumber else { return [normalized(line, foldsCase: foldsCase)] }
            return [normalized(line, foldsCase: foldsCase), normalized(String(rest), foldsCase: foldsCase)]
        }
    }

    private struct ContentsIndex {
        let lines: [LineIndex.Line]
        let labels: Labels
        private var whole: [String: IndexSet] = [:]
        private var wrapped: [String: IndexSet] = [:]
        private var prefixStarts: [Int: IndexSet] = [:]

        init(lines: [LineIndex.Line], labels: Labels) {
            self.lines = lines
            self.labels = labels
            for (position, line) in lines.enumerated() {
                for form in line.forms {
                    whole[form, default: IndexSet()].insert(position)
                    if form.count >= 4 { wrapped[String(form.prefix(4)), default: IndexSet()].insert(position) }
                }
            }
            for (form, starts) in whole {
                if let node = labels.advance(0, by: form) { prefixStarts[node] = starts }
            }
        }

        /// Try master's first whole line or four-character wrap prefix after the previous table.
        func firstRun(of entries: [String], from cursor: Int) -> Range<Int>? {
            guard let first = entries.first else { return nil }
            let exact = whole[first] ?? IndexSet()
            let prefix = first.count > 4 ? wrapped[String(first.prefix(4))] ?? IndexSet() : IndexSet()
            func nextStart(from position: Int) -> Int? {
                [exact, prefix].compactMap { $0.integerGreaterThanOrEqualTo(position) }.min()
            }
            var candidate = nextStart(from: cursor)
            while let start = candidate, lines.count - start >= entries.count {
                let run = orderedRun(entries, from: start)
                if run.matched == entries.count { return start..<run.end }
                candidate = nextStart(from: start + 1)
                if let next = candidate, next < run.end {
                    return overlappingRun(entries, from: next, failedAt: run.matched, exact: exact, prefix: prefix)
                }
            }
            return nil
        }

        /// A numbered line can continue one run and start another. Keep all starts that can reach the
        /// next entry boundary, including both spellings. IndexSet shifts whole ranges of equal-width matches.
        private func overlappingRun(
            _ entries: [String], from lower: Int, failedAt pivot: Int,
            exact: IndexSet, prefix: IndexSet
        ) -> Range<Int>? {
            var upper = min(lines.count, lower + entries.count)
            while upper - lower >= entries.count {
                let window = lower..<upper
                var cache: [String: [Int: IndexSet]] = [:]
                func spans(of entry: String) -> [Int: IndexSet] {
                    if let known = cache[entry] { return known }
                    let spans = lineSpans(of: entry, in: window)
                    cache[entry] = spans
                    return spans
                }

                // The item that broke the first run must actually occur. Use its possible ends before
                // testing a long common suffix; e.g. ABABX followed by several hundred AB pairs.
                // Each preceding and following entry needs at least one physical line of its own.
                let lastPivot = upper - (entries.count - pivot)
                var suffix = IndexSet(integersIn: (lower + pivot)...lastPivot)
                for entry in entries[pivot...] {
                    var ends = IndexSet()
                    for (width, positions) in spans(of: entry) {
                        var next = suffix.intersection(positions)
                        next.shift(startingAt: 0, by: width)
                        ends.formUnion(next)
                    }
                    suffix = ends
                    if suffix.isEmpty { break }
                }
                for entry in entries.reversed() {
                    if suffix.isEmpty { break }
                    var starts = IndexSet()
                    for (width, positions) in spans(of: entry) {
                        var earlier = suffix
                        earlier.remove(integersIn: 0..<width)
                        earlier.shift(startingAt: width, by: -width)
                        starts.formUnion(earlier.intersection(positions))
                    }
                    suffix = starts
                }
                let start = [exact, prefix].compactMap { suffix.intersection($0).first }.min()
                if let start {
                    // The sets establish which start is first; replay it once to get its final line.
                    let run = orderedRun(entries, from: start)
                    if run.matched == entries.count { return start..<run.end }
                }
                // Earlier starts of the same entry finish no later: even its number-stripped spelling
                // starts before the next physical line. Thus the first window with a whole run is sufficient.
                if upper == lines.count { break }
                upper += min(upper - lower, lines.count - upper)
            }
            return nil
        }

        /// Master's comparisons in order. Only the final boundary is needed to exclude a complete run.
        private func orderedRun(_ entries: [String], from start: Int) -> (end: Int, matched: Int) {
            var line = start
            var matched = 0
            for entry in entries {
                guard line < lines.count else { break }
                if lines[line].forms.contains(entry) {
                    line += 1
                } else if let end = endOfWrappedHeading(entry, from: line) {
                    line = end
                } else {
                    break
                }
                matched += 1
            }
            return (line, matched)
        }

        /// A printed prefix can wrap across several lines. Record the same end that the ordered check
        /// would take at that start, including its preference for a whole-line spelling.
        private func lineSpans(of entry: String, in window: Range<Int>) -> [Int: IndexSet] {
            let exact = whole[entry] ?? IndexSet()
            var spans = [1: exact.intersection(IndexSet(integersIn: window))]
            var node = 0
            for character in entry {
                if let positions = prefixStarts[node] {
                    for start in positions[positions.indexRange(in: window)] where !exact.contains(start) {
                        if let end = endOfWrappedHeading(entry, from: start), end <= window.upperBound {
                            spans[end - start, default: IndexSet()].insert(start)
                        }
                    }
                }
                guard let next = labels.prefixes[node].next[character] else { break }
                node = next
            }
            return spans
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
        let target = normalized(heading.text, foldsCase: true)
        let lines = text.components(separatedBy: .newlines).lazy.map { normalized($0, foldsCase: true) }
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
    /// PDF returns an em dash as a combining stroke, which `CharacterSet.alphanumerics` would keep. With `foldsCase`,
    /// case does not take part either; folding can leave a letter as its base and a combining mark (ǰ, ΐ), so the
    /// marks are composed again before the filter drops them.
    private static func normalized(_ text: String, foldsCase: Bool = false) -> String {
        var text = text.precomposedStringWithCompatibilityMapping
        if foldsCase {
            text = text.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }
        return String(
            text.unicodeScalars
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
    public var orgInstructions: OrgFileInstructions?
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
    public var coalescesContentsInLegacy: Bool
    public var inTextNumberMarker: String?
    public var inTextContentsMarker: String?
    public var numberInstructions: ReadingFileInstructions
    public var contentsInstructions: ReadingFileInstructions
    var proposedLeadDepth: Int?
    /// The lead list in print order, independent of the full outline used for bookmarks and page lookup.
    public var leadEntries: [DocumentHeading]?
    public var contentsKinds: Set<ReaderContentsKind>
    public var visibleContentsEntries: [String] = []
    public var hasSourceContents: Bool

    public init(fragment: HTMLFragment) {
        offersLaTeXComposition = fragment.latexClass?.offersCompositionChoice == true
        latexRecognition = fragment.latexClass?.recognition
        coalescesContentsInLegacy = fragment.coalescesContentsInLegacy
        inTextNumberMarker = fragment.inTextNumberMarker
        inTextContentsMarker = fragment.inTextContentsMarker
        numberInstructions = fragment.numberInstructions
        contentsInstructions = fragment.contentsInstructions
        proposedLeadDepth = fragment.proposedLeadContents?.depth
        leadEntries = fragment.leadEntries
        contentsKinds = fragment.sourceContentsKinds
        orgInstructions = fragment.orgInstructions
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
