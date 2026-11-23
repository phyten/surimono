import Foundation

/// Pair equal spellings by ordinal in the entire prose and paper. Equal counts alone are insufficient:
/// if a header replaces a missing body hit, its neighbouring text must still agree. Never take a partial group.
struct ProsePaperIndex {
    private struct Folded {
        let raw: NSString
        let letters: [UInt16]
        /// Raw UTF-16 start of each folded unit, followed by the raw end of the text.
        let offsets: [Int]
        let objects: [Int]
        // PDFKit can merge adjacent lowercase l glyphs. Count every possible spelling before
        // checking spaces or glyph counts, even if a physical line ends between the two glyphs.
        let lRuns: [Int: [Int]]

        init(_ text: String) throws {
            let raw = text as NSString
            var units: [UInt16] = []
            var offsets: [Int] = []
            var objects: [Int] = []
            var lRuns: [Int: [Int]] = [:]
            for (offset, unit) in text.utf16.enumerated() {
                if offset.isMultiple(of: 8192) { try Task.checkCancellation() }
                if Self.space(unit) { continue }
                if unit == 0x6C, units.last == unit {
                    let i = units.count - 1
                    lRuns[i, default: [offsets[i]]].append(offset)
                    continue
                }
                if unit == 0xFFFC { objects.append(units.count) }
                units.append(unit)
                offsets.append(offset)
            }
            offsets.append(raw.length)
            self.lRuns = lRuns
            self.objects = objects
            self.raw = raw
            self.letters = units
            self.offsets = offsets
        }

        static func space(_ unit: UInt16) -> Bool {
            Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }

        func foldedRange(of rawRange: Range<Int>) -> Range<Int> {
            let start = letters.indices.partitionIndex { rawEnd(at: $0) > rawRange.lowerBound }
            let end = offsets.partitionIndex { $0 >= rawRange.upperBound }
            return start..<end
        }

        func rawRange(_ range: Range<Int>) -> Range<Int> {
            offsets[range.lowerBound]..<rawEnd(at: range.upperBound - 1)
        }

        func spelling(at start: Int, length: Int) -> String {
            raw.substring(with: NSRange(rawRange(start..<(start + length))))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        func hasLineBreak(in gap: Range<Int>) -> Bool {
            !gap.isEmpty
                && raw.rangeOfCharacter(from: .newlines, options: [], range: NSRange(gap)).location != NSNotFound
        }

        func rawEnd(at index: Int) -> Int {
            (lRuns[index]?.last ?? offsets[index]) + 1
        }
    }

    private struct Place {
        let range: Range<Int>
        let raw: Range<Int>
        let segment: Int
        let pattern: Int
    }

    private struct Passage {
        let range: Range<Int>
        let paperStart: Int
        // A printed glyph cannot represent just one side of this source boundary.
        var contractions = IndexSet()
        // Only multi-glyph runs need an individual offset when a finding ends inside the run.
        var glyphOffsets: [Int: Int] = [:]
    }

    private let source: Folded
    private let paper: Folded
    private let pages: [Range<Int>]
    private let paragraphsOnSource: [Range<Int>]
    private let sharedLBreaks: IndexSet
    private let places: [ProseOccurrence: Place]
    private var passages: [Int: Passage] = [:]
    private let originals: [[Int]]
    private let printed: [[Int]]
    private var ambiguous: Set<Int> = []

    init(paragraphs: [String], pages: [String], occurrences: [ProseOccurrence]) throws {
        func ranges(_ parts: [String]) -> [Range<Int>] {
            var offset = 0
            return parts.map {
                let end = offset + $0.utf16.count
                defer { offset = end + 1 }
                return offset..<end
            }
        }
        paragraphsOnSource = ranges(paragraphs)
        self.pages = ranges(pages)
        (source, sharedLBreaks) = try Self.foldParagraphs(paragraphs, ranges: paragraphsOnSource)
        paper = try Folded(pages.joined(separator: "\n"))

        var patterns = ProsePatternIndex()
        var segments: [Int: (range: Range<Int>, pattern: Int)] = [:]
        var places: [ProseOccurrence: Place] = [:]
        for occurrence in occurrences {
            try Task.checkCancellation()
            let paragraph = paragraphsOnSource[occurrence.paragraph]
            let range = occurrence.textRange
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= paragraph.count else { continue }
            let raw = (paragraph.lowerBound + range.lowerBound)..<(paragraph.lowerBound + range.upperBound)
            // Matching discards whitespace, so it cannot prove an endpoint inside a gap.
            guard !Folded.space(source.raw.character(at: raw.lowerBound)),
                !Folded.space(source.raw.character(at: raw.upperBound - 1))
            else { continue }
            let folded = source.foldedRange(of: raw)
            let start = folded.lowerBound
            let end = folded.upperBound
            let segment = source.objects.partitionIndex { $0 >= start }
            let upper = segment < source.objects.count ? source.objects[segment] : source.letters.count
            guard start < end, end <= upper else { continue }
            if segments[segment] == nil {
                let lower = segment == 0 ? 0 : source.objects[segment - 1] + 1
                let id = try patterns.register(source.letters[lower..<upper])
                segments[segment] = (lower..<upper, id)
            }
            let pattern = try patterns.register(source.letters[start..<end])
            places[occurrence] = Place(range: start..<end, raw: raw, segment: segment, pattern: pattern)
        }
        self.places = places
        try patterns.prepare()
        originals = try patterns.matches(in: source.letters)
        printed = try patterns.matches(in: paper.letters)

        // If genuinely different source spellings share a pattern, their order only proves a
        // match while the printed spellings still distinguish them. Check passages as well as hits.
        for (id, length) in patterns.lengths.enumerated() {
            let hits = originals[id]
            guard hits.count > 1, hits.count == printed[id].count, let first = hits.first,
                length > 1 || source.letters[first] == 0x6C
            else { continue }
            let spelling = source.spelling(at: first, length: length)
            let mixed = try hits.dropFirst().contains { start in
                try Task.checkCancellation()
                return source.spelling(at: start, length: length) != spelling
            }
            if mixed {
                for (sourceHit, paperHit) in zip(hits, printed[id]) {
                    try Task.checkCancellation()
                    if source.spelling(at: sourceHit, length: length) != paper.spelling(at: paperHit, length: length) {
                        ambiguous.insert(id)
                        break
                    }
                }
            }
        }

        // All findings in a paragraph (or passage between inline objects) use the same verified alignment.
        for (segment, entry) in segments {
            try Task.checkCancellation()
            let range = entry.range
            if let hit = paired(range.lowerBound, pattern: entry.pattern) {
                passages[segment] = try passage(range, at: hit)
            }
        }
    }

    private static func foldParagraphs(_ paragraphs: [String], ranges: [Range<Int>]) throws -> (Folded, IndexSet) {
        // A printed l run can include glyphs from both sides of a paragraph break. Verify those
        // paragraphs together, even when the neighbour has no findings. Keep every other separator
        // opaque to matching and preserve the original UTF-16 offsets.
        var sourceText = ""
        var trailingL = false
        var sharedBreaks = IndexSet()
        for (i, paragraph) in paragraphs.enumerated() {
            try Task.checkCancellation()
            let units = paragraph.utf16
            let first = units.first { !Folded.space($0) }
            if i > 0 {
                if trailingL && (first == 0x6C || first == nil) {
                    sharedBreaks.insert(ranges[i - 1].upperBound)
                    sourceText.append("\n")
                } else {
                    sourceText.append("\u{FFFC}")
                }
            }
            sourceText += paragraph
            if first != nil { trailingL = units.last { !Folded.space($0) } == 0x6C }
        }
        return (try Folded(sourceText), sharedBreaks)
    }

    private func paired(_ offset: Int, pattern: Int) -> Int? {
        let candidates = originals[pattern]
        guard !ambiguous.contains(pattern), candidates.count == printed[pattern].count else { return nil }
        let ordinal = candidates.partitionIndex { $0 >= offset }
        guard ordinal < candidates.count, candidates[ordinal] == offset else { return nil }
        return printed[pattern][ordinal]
    }

    func spans(for occurrences: [ProseOccurrence], longSentence: Bool = false) throws -> [ProsePaperSpan] {
        var spans: [ProsePaperSpan] = []
        for occurrence in occurrences {
            try Task.checkCancellation()
            guard let place = places[occurrence], let passage = passages[place.segment],
                let hit = paired(place.range.lowerBound, pattern: place.pattern),
                hit == passage.paperStart + (place.range.lowerBound - passage.range.lowerBound)
            else { return [] }
            guard !passage.contractions.contains(place.raw.lowerBound),
                !passage.contractions.contains(place.raw.upperBound)
            else { return [] }
            if passage.contractions.intersects(integersIn: paragraphsOnSource[occurrence.paragraph]) {
                guard longSentence, occurrence.isEnglish,
                    place.range.contains(where: { source.lRuns[$0] != nil })
                else { return [] }
            }
            let last = hit + place.range.count - 1
            let lower = passage.glyphOffsets[place.raw.lowerBound] ?? paper.offsets[hit]
            let upper = passage.glyphOffsets[place.raw.upperBound - 1].map { $0 + 1 } ?? paper.rawEnd(at: last)
            let printed = lower..<upper
            let first = pages.partitionIndex { $0.upperBound > printed.lowerBound }
            for page in first..<pages.count {
                guard pages[page].lowerBound < printed.upperBound else { break }
                let part = printed.clamped(to: pages[page])
                if !part.isEmpty {
                    spans.append(
                        ProsePaperSpan(
                            page: page,
                            range: NSRange(location: part.lowerBound - pages[page].lowerBound, length: part.count),
                            text: paper.raw.substring(with: NSRange(part))))
                }
            }
        }
        return spans
    }

    private func passage(_ range: Range<Int>, at hit: Int) throws -> Passage? {
        let printed = paper.rawRange(hit..<(hit + range.count))
        // A standalone word cannot be proved by the matching prefix of a longer printed word.
        func insideWord(at boundary: Int) -> Bool {
            guard boundary > 0, boundary < paper.raw.length else { return false }
            return [boundary - 1, boundary].allSatisfy {
                Unicode.Scalar(paper.raw.character(at: $0)).map { CharacterSet.alphanumerics.contains($0) } ?? false
            }
        }
        guard !insideWord(at: printed.lowerBound), !insideWord(at: printed.upperBound) else { return nil }
        var passage = Passage(range: range, paperStart: hit)
        for i in range {
            if i.isMultiple(of: 8192) { try Task.checkCancellation() }
            let j = hit + (i - range.lowerBound)
            if i > range.lowerBound,
                !spacingAgrees(
                    sourceGap: source.offsets[i] > source.rawEnd(at: i - 1),
                    paperGap: paper.rawEnd(at: j - 1)..<paper.offsets[j])
            {
                return nil
            }
            if source.lRuns[i] != nil || paper.lRuns[j] != nil {
                let original = source.lRuns[i] ?? [source.offsets[i]]
                let printed = paper.lRuns[j] ?? [paper.offsets[j]]
                guard alignLs(original, printed, passage: &passage) else { return nil }
            }
        }
        return passage
    }

    private func spacingAgrees(sourceGap: Bool, paperGap: Range<Int>) -> Bool {
        if sourceGap == !paperGap.isEmpty { return true }
        // A physical line break may split a word. A horizontal space may not.
        return paper.hasLineBreak(in: paperGap)
    }

    private func alignLs(_ original: [Int], _ printed: [Int], passage: inout Passage) -> Bool {
        if original.count == printed.count {
            for i in original.indices {
                if i > 0 {
                    let sourceGap = (original[i - 1] + 1)..<original[i]
                    let paperGap = (printed[i - 1] + 1)..<printed[i]
                    guard spacingAgrees(sourceGap: !sourceGap.isEmpty, paperGap: paperGap) else { return false }
                    if sharedLBreaks.intersects(integersIn: sourceGap), !paper.hasLineBreak(in: paperGap) {
                        return false
                    }
                }
                passage.glyphOffsets[original[i]] = printed[i]
            }
            return true
        }
        // Once glyph counts differ at a shared run, a soft wrap and a paragraph break can
        // assign the same printed l to different paragraphs. Neither paragraph owns a proven range.
        guard !sharedLBreaks.intersects(integersIn: original[0]..<original[original.count - 1]) else { return false }
        // Only a pair within a word may contract. Spaces between words still anchor their glyphs.
        var i = 0
        var j = 0
        while i < original.count, j < printed.count {
            var end = i + 1
            while end < original.count, original[end] == original[end - 1] + 1 { end += 1 }
            var printedEnd = j + 1
            while printedEnd < printed.count, printed[printedEnd] == printed[printedEnd - 1] + 1 { printedEnd += 1 }
            if end - i == printedEnd - j {
                for k in i..<end { passage.glyphOffsets[original[k]] = printed[j + (k - i)] }
            } else if end - i == 2, printedEnd - j == 1 {
                passage.contractions.insert(original[i + 1])
                passage.glyphOffsets[original[i]] = printed[j]
                passage.glyphOffsets[original[i + 1]] = printed[j]
            } else {
                return false
            }
            i = end
            j = printedEnd
        }
        return i == original.count && j == printed.count
    }
}

extension RandomAccessCollection where Index == Int {
    fileprivate func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
