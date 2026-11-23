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
    /// DOM positions in `sourceContents` distinguish the source tables from identical runs of body text.
    /// Callers with only the legacy flat list separate tables with an empty label.
    public static func pages(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = [],
        sourceContents: [SourceContents] = []
    ) -> [Int?] {
        var index = LineIndex(pages: pages)
        if sourceContents.isEmpty {
            index.exclude(contentsEntries.map(normalized))
        } else {
            index.exclude(sourceContents)
        }
        var cursor = 0
        // The exclusions are final and the cursor only moves forward, so a miss stays a miss.
        var missingTargets: Set<String> = []
        return headings.map { heading in
            let target = normalized(heading.text)
            guard !target.isEmpty, !missingTargets.contains(target) else { return nil }
            guard let match = index.firstMatch(of: target, from: cursor) else {
                missingTargets.insert(target)
                return nil
            }
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
        // Alternating lower and upper bounds of gaps where this label might be an unlocated table entry.
        private var uncertainBounds: [String: [Int]] = [:]

        /// Shared across all tables, including candidate enumeration, sorting and exclusion.
        private let contentsBudget: Int

        init(pages: [String]) {
            contentsBudget = 256 + 64 * pages.reduce(0) { $0 + $1.utf8.count }
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

        /// Index distinct labels once per table. A short prefix narrows the candidates when one of
        /// the entries wraps, without storing every character prefix of a potentially very long title.
        private struct Table {
            let labels: [String]
            var counts: [String: Int] = [:]
            var prefixes: [String: [String]] = [:]
            var characterCount = 0
            var byteCount = 0

            init(_ labels: [String]) {
                self.labels = labels.filter { !$0.isEmpty }
                for label in self.labels {
                    let length = label.count
                    characterCount += length
                    byteCount += label.utf8.count
                    counts[label, default: 0] += 1
                    guard counts[label] == 1, length > 1 else { continue }
                    for count in 1...min(length - 1, wrappedPrefixLength) {
                        prefixes[String(label.prefix(count)), default: []].append(label)
                    }
                }
            }
        }

        private enum Location {
            case found(Range<Int>)
            case ambiguous([Range<Int>], Query)
            case missing
            case alreadyHandled
        }

        private struct Query: Hashable {
            let labels: [String]
            let captions: [String]
            let before: String
            let after: String
        }

        private enum SearchLimit: Error { case exhausted }

        private struct Cursor {
            var remaining: Int
            // Anchor occurrences belong to the whole document. Completed searches belong to the current floor.
            var anchors: [String: [Range<Int>]] = [:]
            var handledQueries: Set<Query> = []
            var line = 0
            var aligned = true
            var missing: Set<String> = []

            mutating func spend(_ units: Int) throws {
                guard units <= remaining, remaining > 0 else {
                    remaining = 0
                    throw SearchLimit.exhausted
                }
                remaining -= units
            }

            mutating func spendSort(_ count: Int) throws {
                try spend(count * (Int.bitWidth - count.leadingZeroBitCount))
            }

            mutating func advance(to end: Int) {
                line = end
                aligned = true
                missing.removeAll()
                handledQueries.removeAll()
            }
        }

        mutating func exclude(_ blocks: [SourceContents]) {
            var cursor = Cursor(remaining: contentsBudget)
            for block in blocks { exclude(Table(block.entries.map(normalized)), block: block, cursor: &cursor) }
            recordGap(cursor, until: lines.count)
        }

        mutating func exclude(_ entries: [String]) {
            var cursor = Cursor(remaining: contentsBudget)
            for labels in entries.split(separator: "") { exclude(Table(Array(labels)), block: nil, cursor: &cursor) }
            recordGap(cursor, until: lines.count)
        }

        private mutating func recordGap(_ cursor: Cursor, until end: Int) {
            guard cursor.line < end else { return }
            for label in cursor.missing {
                uncertainBounds[label, default: []].append(contentsOf: [cursor.line, end])
            }
        }

        private mutating func exclude(_ table: Table, block: SourceContents?, cursor: inout Cursor) {
            guard !table.labels.isEmpty else { return }
            guard cursor.remaining > 0 else {
                cursor.missing.formUnion(table.labels)
                return
            }
            do {
                let location: Location
                if let block, cursor.aligned,
                    let start = endOfPrefix(normalized(block.precedingText), from: cursor.line),
                    let match = try? candidate(table, at: start, positioned: true, cursor: &cursor)
                {
                    location = .found(start..<match.end)
                } else {
                    location = try locate(table, block: block, cursor: &cursor)
                }
                cursor.aligned = false
                switch location {
                case .found(let range):
                    try cursor.spend(range.count)
                    recordGap(cursor, until: range.lowerBound)
                    excluded.formUnion(range)
                    cursor.advance(to: range.upperBound)
                case .ambiguous(let candidates, let query):
                    for range in candidates {
                        try cursor.spend(range.count)
                        excluded.formUnion(range)
                    }
                    cursor.handledQueries.insert(query)
                case .alreadyHandled: break
                case .missing:
                    // The legacy flat list can describe a table which was never printed.
                    if block != nil { cursor.missing.formUnion(table.labels) }
                }
            } catch {
                // A partial search cannot certify a unique candidate.
                cursor.aligned = false
                cursor.missing.formUnion(table.labels)
            }
        }

        private func endOfPrefix(_ text: String, from start: Int) -> Int? {
            var rest = text[...]
            var line = start
            while !rest.isEmpty {
                guard line < lines.count,
                    let form = lines[line].forms.first(where: { !$0.isEmpty && rest.hasPrefix($0) })
                else { return nil }
                rest = rest.dropFirst(form.count)
                line += 1
            }
            return line
        }

        /// Recover this table independently. A neighbouring body block can locate a titleless local table
        /// from either side. Without a position, only a unique run in source order is evidence.
        private func locate(_ table: Table, block: SourceContents?, cursor: inout Cursor) throws -> Location {
            let query = Query(
                labels: table.labels,
                captions: block.map { [normalized($0.caption)] } ?? ["目次", "Contents", "TableofContents"],
                before: normalized(block?.previousBlock ?? ""), after: normalized(block?.followingBlock ?? ""))
            if cursor.handledQueries.contains(query) { return .alreadyHandled }
            let previous = try occurrences(of: query.before, cursor: &cursor)
            let following = try occurrences(of: query.after, cursor: &cursor)
            try cursor.spend(previous.count + 3 * following.count)
            var left: [Int: Int] = [:]
            for range in previous { left[range.upperBound] = 1 }
            for caption in query.captions {
                let ranges = try occurrences(of: caption, cursor: &cursor)
                try cursor.spend(ranges.count)
                for range in ranges { left[range.upperBound] = left[range.lowerBound] == 1 ? 3 : 2 }
            }
            let right = following.map(\.lowerBound)
            let rightEnds = Set(right)
            var nextRight = 0
            var candidates: [Range<Int>] = []
            var bestRank = -1
            try cursor.spend(left.count)
            var starts = Set(left.keys)
            var covered = cursor.line
            for end in right {
                let lower = max(covered, end - table.characterCount)
                let upper = end - table.labels.count + 1
                if lower < upper {
                    try cursor.spend(upper - lower)
                    starts.formUnion(lower..<upper)
                    covered = upper
                }
            }
            // Even when the DOM supplies both neighbours, printing can change both. Include the first
            // entry's possible starts; a run without an anchor must match all entries in source order.
            func addStarts(_ positions: [Int]) throws {
                let eligible = positions[Self.firstPosition(in: positions, atLeast: cursor.line)...]
                try cursor.spend(eligible.count)
                starts.formUnion(eligible)
            }
            if let first = table.labels.first {
                try addStarts(whole[first] ?? [])
                try addStarts(wrapped[String(first.prefix(Self.wrappedPrefixLength))] ?? [])
                for length in 1..<min(first.count + 1, Self.wrappedPrefixLength) {
                    try addStarts(whole[String(first.prefix(length))] ?? [])
                }
            }
            try cursor.spendSort(starts.count)
            for start in starts.sorted() where start < lines.count {
                while nextRight < right.count, right[nextRight] < start + table.labels.count { nextRight += 1 }
                let nearEnd = nextRight < right.count && right[nextRight] - start <= table.characterCount
                let leftScore = left[start] ?? 0
                guard let match = try candidate(table, at: start, positioned: leftScore > 0 || nearEnd, cursor: &cursor)
                else { continue }
                let evidence = leftScore + (rightEnds.contains(match.end) ? 1 : 0)
                guard evidence > 0 || match.ordered else { continue }
                let rank = evidence * 2 + (match.ordered ? 1 : 0)
                if rank > bestRank {
                    candidates = [start..<match.end]
                    bestRank = rank
                } else if rank == bestRank {
                    candidates.append(start..<match.end)
                }
            }
            guard let first = candidates.first else {
                cursor.handledQueries.insert(query)
                return .missing
            }
            if candidates.count == 1 { return .found(first) }
            return .ambiguous(candidates, query)
        }

        /// Index both exact and wrapped anchors once. Later tables take a slice starting at their own floor.
        private func occurrences(of text: String, cursor: inout Cursor) throws -> ArraySlice<Range<Int>> {
            guard !text.isEmpty else { return [] }
            if cursor.anchors[text] == nil {
                let exact = whole[text] ?? []
                try cursor.spend(exact.count)
                var ranges = exact.map { $0..<($0 + 1) }
                if text.count > Self.wrappedPrefixLength {
                    let starts = wrapped[String(text.prefix(Self.wrappedPrefixLength))] ?? []
                    try cursor.spend(starts.count)
                    for start in starts where !lines[start].forms.contains(text) {
                        for form in lines[start].forms {
                            if let end = endOfWrappedLabel(text, first: form, from: start, budget: &cursor.remaining) {
                                ranges.append(start..<end)
                                break
                            }
                            if cursor.remaining <= 0 { throw SearchLimit.exhausted }
                        }
                    }
                    if ranges.count > exact.count {
                        try cursor.spendSort(ranges.count)
                        ranges.sort { $0.lowerBound < $1.lowerBound }
                    }
                }
                cursor.anchors[text] = ranges
            }
            let ranges = cursor.anchors[text] ?? []
            return ranges[Self.firstPosition(in: ranges, atLeast: cursor.line, position: \.lowerBound)...]
        }

        private func candidate(_ table: Table, at start: Int, positioned: Bool, cursor: inout Cursor)
            throws -> (end: Int, ordered: Bool)?
        {
            let allowance = min(cursor.remaining, 64 + 8 * (table.byteCount + table.labels.count))
            var budget = allowance
            let ordered = match(table, at: start, ordered: true, budget: &budget)
            let end = ordered ?? (positioned ? match(table, at: start, ordered: false, budget: &budget) : nil)
            cursor.remaining -= allowance - max(0, budget)
            guard budget > 0 else { throw SearchLimit.exhausted }
            return end.map { ($0, ordered != nil) }
        }

        /// Advance past one disjoint line range per entry. Number-stripped forms must themselves spell
        /// a whole unused label. Never transfer a digit or any other character between two labels.
        private func match(_ table: Table, at start: Int, ordered: Bool, budget: inout Int) -> Int? {
            var used: [String: Int] = [:]
            var line = start
            for expected in table.labels {
                guard line < lines.count, budget > 0 else { return nil }
                func available(_ label: String) -> Bool {
                    ordered ? label == expected : used[label, default: 0] < table.counts[label, default: 0]
                }
                budget -= 1
                if let label = lines[line].forms.first(where: available) {
                    if !ordered { used[label, default: 0] += 1 }
                    line += 1
                    continue
                }
                var wrapped: (label: String, end: Int)?
                for first in lines[line].forms where !first.isEmpty {
                    let prefix = String(first.prefix(Self.wrappedPrefixLength))
                    let candidates = ordered ? [expected] : table.prefixes[prefix] ?? []
                    for label in candidates {
                        budget -= 1
                        guard budget > 0 else { return nil }
                        if available(label),
                            let end = endOfWrappedLabel(label, first: first, from: line, budget: &budget)
                        {
                            wrapped = (label, end)
                            break
                        }
                    }
                    if wrapped != nil { break }
                }
                guard let wrapped else { return nil }
                if !ordered { used[wrapped.label, default: 0] += 1 }
                line = wrapped.end
            }
            return line
        }

        func firstMatch(of target: String, from cursor: Int) -> (page: Int, end: Int)? {
            let bounds = uncertainBounds[target] ?? []
            func canUse(_ line: Int) -> Bool {
                !excluded.contains(line) && Self.firstPosition(in: bounds, atLeast: line + 1).isMultiple(of: 2)
            }
            var best: (page: Int, end: Int, start: Int)?
            let exact = whole[target] ?? []
            var start = Self.firstPosition(in: exact, atLeast: cursor)
            while start < exact.count, !canUse(exact[start]) { start += 1 }
            if start < exact.count {
                best = (lines[exact[start]].page, exact[start] + 1, exact[start])
            }
            guard target.count > Self.wrappedPrefixLength else { return best.map { ($0.page, $0.end) } }
            let candidates = wrapped[String(target.prefix(Self.wrappedPrefixLength))] ?? []
            var position = Self.firstPosition(in: candidates, atLeast: cursor)
            while position < candidates.count, candidates[position] < best?.start ?? .max {
                let start = candidates[position]
                if canUse(start), let end = endOfWrappedHeading(target, from: start),
                    (start..<end).allSatisfy(canUse)
                {
                    best = (lines[start].page, end, start)
                    break
                }
                position += 1
            }
            return best.map { ($0.page, $0.end) }
        }

        /// The index after the last line of a heading that wraps from `start`. It stays on one page.
        private func endOfWrappedHeading(_ target: String, from start: Int) -> Int? {
            var budget = Int.max
            for form in lines[start].forms {
                if let end = endOfWrappedLabel(target, first: form, from: start, budget: &budget) { return end }
            }
            return nil
        }

        private func endOfWrappedLabel(_ label: String, first: String, from start: Int, budget: inout Int) -> Int? {
            var rest = label[...]
            var line = start
            while line < lines.count, lines[line].page == lines[start].page {
                let form = line == start ? first : lines[line].forms[0]
                // Charge the shorter operand, including failed prefix comparisons.
                budget -= min(rest.utf8.count, form.utf8.count) + 1
                guard budget > 0, !form.isEmpty, rest.hasPrefix(form) else { return nil }
                rest = rest.dropFirst(form.count)
                line += 1
                if rest.isEmpty { return line }
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
            let full = normalized(line)
            let stripped = normalized(String(rest))
            return full == stripped || stripped.isEmpty ? [full] : [full, stripped]
        }

        private static func firstPosition(in sorted: [Int], atLeast value: Int) -> Int {
            firstPosition(in: sorted, atLeast: value, position: { $0 })
        }

        private static func firstPosition<T>(in sorted: [T], atLeast value: Int, position: (T) -> Int) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if position(sorted[middle]) < value { low = middle + 1 } else { high = middle }
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

    public static func entries(
        of headings: [DocumentHeading], inPageTexts pages: [String], contentsEntries: [String] = [],
        sourceContents: [SourceContents] = []
    ) -> [OutlineEntry] {
        zip(
            headings,
            self.pages(
                of: headings, inPageTexts: pages, contentsEntries: contentsEntries, sourceContents: sourceContents)
        ).map {
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
