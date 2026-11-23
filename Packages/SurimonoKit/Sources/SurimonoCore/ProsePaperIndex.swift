import Foundation

/// Pair equal spellings by ordinal in the entire prose and paper. Equal counts alone are insufficient:
/// if a header replaces a missing body hit, its neighbouring text must still agree. Never take a partial group.
struct ProsePaperIndex {
    private struct Folded {
        let raw: NSString
        let letters: NSString
        /// Raw UTF-16 offset of each non-space unit, including one end sentinel.
        let offsets: [Int]
        let objects: [Int]

        init(_ text: String) throws {
            let raw = text as NSString
            var units: [UInt16] = []
            var offsets: [Int] = []
            var objects: [Int] = []
            for (offset, unit) in text.utf16.enumerated() {
                if offset.isMultiple(of: 8192) { try Task.checkCancellation() }
                if Self.space(unit) { continue }
                if unit == 0xFFFC { objects.append(units.count) }
                units.append(unit)
                offsets.append(offset)
            }
            offsets.append(raw.length)
            self.objects = objects
            self.raw = raw
            self.letters = String(decoding: units, as: UTF16.self) as NSString
            self.offsets = offsets
        }

        static func space(_ unit: UInt16) -> Bool {
            Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }

        func rawRange(_ range: Range<Int>) -> Range<Int> {
            offsets[range.lowerBound]..<(offsets[range.upperBound - 1] + 1)
        }

        func matches(_ needle: String) throws -> [Int] {
            var hits: [Int] = []
            var start = 0
            while start < letters.length {
                try Task.checkCancellation()
                let range = letters.range(of: needle, options: .literal, range: NSRange(start..<letters.length))
                guard range.location != NSNotFound else { break }
                hits.append(range.location)
                // Overlapping runs count too (three kana can contain the same pair twice).
                start = range.location + 1
            }
            return hits
        }
    }

    private let source: Folded
    private let paper: Folded
    private let paragraphs: [Range<Int>]
    private let pages: [Range<Int>]
    private struct Alignment: Hashable {
        let segment: Int
        let delta: Int
    }

    private var alignments: [Alignment: Bool] = [:]
    private var pairs: [String: [Int: Int]] = [:]

    init(paragraphs: [String], pages: [String]) throws {
        func ranges(_ parts: [String]) -> [Range<Int>] {
            var offset = 0
            return parts.map {
                let end = offset + $0.utf16.count
                defer { offset = end + 1 }
                return offset..<end
            }
        }
        self.paragraphs = ranges(paragraphs)
        self.pages = ranges(pages)
        // A match cannot bridge separate prose paragraphs. A line or page break in the PDF can split a sentence.
        source = try Folded(paragraphs.joined(separator: "\u{FFFC}"))
        paper = try Folded(pages.joined(separator: "\n"))
    }

    mutating func spans(for occurrences: [ProseOccurrence]) throws -> [ProsePaperSpan] {
        var spans: [ProsePaperSpan] = []
        for occurrence in occurrences {
            let paragraph = paragraphs[occurrence.paragraph]
            let range = occurrence.textRange
            let raw = (paragraph.lowerBound + range.lowerBound)..<(paragraph.lowerBound + range.upperBound)
            let start = source.offsets.partitionIndex { $0 >= raw.lowerBound }
            let end = source.offsets.partitionIndex { $0 >= raw.upperBound }
            guard start < end else { return [] }
            let needle = source.letters.substring(with: NSRange(start..<end))
            guard !needle.contains("\u{FFFC}") else { return [] }
            if pairs[needle] == nil {
                let originals = try source.matches(needle)
                let printed = try paper.matches(needle)
                pairs[needle] =
                    originals.count == printed.count
                    ? Dictionary(uniqueKeysWithValues: zip(originals, printed)) : [:]
            }
            guard let hit = pairs[needle]?[start],
                try agrees(sourceStart: start, paperStart: hit)
            else { return [] }
            let printed = paper.rawRange(hit..<(hit + end - start))
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

    private mutating func agrees(sourceStart: Int, paperStart: Int) throws -> Bool {
        // Check the whole passage bounded by a paragraph break or inline object, once for all
        // findings with the same alignment. A short matching prefix can also occur in another chapter.
        let segment = source.objects.partitionIndex { $0 >= sourceStart }
        let delta = paperStart - sourceStart
        let key = Alignment(segment: segment, delta: delta)
        if let verified = alignments[key] { return verified }
        let start = segment == 0 ? 0 : source.objects[segment - 1] + 1
        let end = segment == source.objects.count ? source.letters.length : source.objects[segment]
        let verified = try matchesPassage(start: start, end: end, delta: delta)
        alignments[key] = verified
        return verified
    }

    private func matchesPassage(start: Int, end: Int, delta: Int) throws -> Bool {
        guard start + delta >= 0, end + delta <= paper.letters.length else { return false }
        let passage = paper.rawRange((start + delta)..<(end + delta))
        // A standalone word cannot be proved by the matching prefix of a longer printed word.
        func insideWord(at boundary: Int) -> Bool {
            guard boundary > 0, boundary < paper.raw.length else { return false }
            return [boundary - 1, boundary].allSatisfy {
                Unicode.Scalar(paper.raw.character(at: $0)).map { CharacterSet.alphanumerics.contains($0) } ?? false
            }
        }
        guard !insideWord(at: passage.lowerBound), !insideWord(at: passage.upperBound) else { return false }
        for i in start..<end {
            if i.isMultiple(of: 8192) { try Task.checkCancellation() }
            let j = i + delta
            guard source.letters.character(at: i) == paper.letters.character(at: j) else { return false }
            guard i > start else { continue }
            let sourceSpace = source.offsets[i] > source.offsets[i - 1] + 1
            let gap = (paper.offsets[j - 1] + 1)..<paper.offsets[j]
            if sourceSpace != !gap.isEmpty {
                // A physical line break may split a Japanese word. A horizontal space may not.
                guard !gap.isEmpty,
                    paper.raw.rangeOfCharacter(from: .newlines, options: [], range: NSRange(gap)).location != NSNotFound
                else { return false }
            }
        }
        return true
    }
}

extension Array {
    fileprivate func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
