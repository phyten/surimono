import Foundation
import RobustnessSupport
import Testing

@testable import SurimonoCore

struct ProsePaperDifferentialTests {
    // In this ASCII alphabet every byte is one UTF-16 unit. A soft wrap has no source unit,
    // a replaced space has one, and a coalesced glyph has two. Paragraph separators have their own offset.
    private struct Extraction {
        var units: [UInt8] = []
        var origins: [Range<Int>?] = []

        private mutating func append(_ byte: UInt8, from origin: Range<Int>?) {
            units.append(byte)
            origins.append(origin)
        }

        mutating func appendParagraph(_ bytes: [UInt8], base: Int, permitsShrink: Bool, pick: (Int) -> Int) {
            if base > 0 { append(UInt8(ascii: "\n"), from: (base - 1)..<base) }
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if i > 0, byte != UInt8(ascii: " "), bytes[i - 1] != UInt8(ascii: " "), pick(5) == 0 {
                    append(UInt8(ascii: "\n"), from: nil)
                }
                let shrink =
                    permitsShrink && byte == UInt8(ascii: "l") && i + 1 < bytes.count
                    && bytes[i + 1] == UInt8(ascii: "l") && pick(2) == 0
                let next = i + (shrink ? 2 : 1)
                append(
                    byte == UInt8(ascii: " ") && pick(3) == 0 ? UInt8(ascii: "\n") : byte,
                    from: (base + i)..<(base + next))
                i = next
            }
        }

        func covers(_ span: ProsePaperSpan, source: Range<Int>) -> Bool {
            guard span.page == 0, let range = Range(span.range), !range.isEmpty,
                range.lowerBound >= 0, range.upperBound <= units.count,
                origins[range.lowerBound] != nil, origins[range.upperBound - 1] != nil,
                String(decoding: units[range], as: UTF8.self) == span.text
            else { return false }
            var next = source.lowerBound
            for origin in origins[range].compactMap({ $0 }) {
                guard origin.lowerBound == next else { return false }
                next = origin.upperBound
            }
            return next == source.upperBound
        }
    }

    @Test("縮約と折り返しを加えた紙面の印は元の段落の指摘範囲だけを覆う", arguments: 0..<16)
    func mappedCharacters(batch: Int) throws {
        for sample in 0..<200 {
            let seed = SeededGenerator.caseSeed(0x275_04, "paper", batch * 200 + sample)
            var random = SeededGenerator(seed: seed)
            func pick(_ count: Int) -> Int { Int(random.next() % UInt64(count)) }
            let unique = sample.isMultiple(of: 4)
            let vocabulary = ["l", "ll", "all", "la", "ll", "a", "ball", "al", "lab"]
            var paragraphs: [String] = []
            var hits: [ProseOccurrence] = []
            var paper = Extraction()
            var base = 0
            for paragraph in 0..<(2 + pick(3)) {
                var words = (0..<(2 + pick(3))).map { _ in vocabulary[pick(vocabulary.count)] }
                if pick(2) == 0 { words[1] = words[0] }
                if unique { words.insert("x\(paragraph)x", at: 1) }
                if !unique, paragraph > 0, pick(4) == 0 {
                    words = paragraphs[pick(paragraph)].split(separator: " ").map(String.init)
                }
                let text = words.joined(separator: " ")
                paragraphs.append(text)
                let bytes = Array(text.utf8)
                let start = pick(bytes.count)
                let end = start + 1 + pick(bytes.count - start)
                var ranges = [0..<bytes.count]
                if unique {
                    // The marker belongs to one paragraph and both queries include it.
                    ranges.append(0..<(words[0].utf8.count + 1 + words[1].utf8.count))
                } else {
                    // Probe endpoints inside pairs and whitespace too, so a partial match cannot pass.
                    ranges.append(start..<end)
                    var offset = 0
                    for i in words.indices {
                        let length = words[i].utf8.count
                        if i > 0, words[i] == words[i - 1] {
                            ranges.append((offset - length - 1)..<(offset + length))
                        }
                        offset += length + 1
                    }
                }
                for range in ranges {
                    hits.append(
                        ProseOccurrence(
                            paragraph: paragraph, sourceRange: (base + range.lowerBound)..<(base + range.upperBound),
                            textRange: range, sentenceRange: 0..<bytes.count, isEnglish: true))
                }
                paper.appendParagraph(bytes, base: base, permitsShrink: !unique, pick: pick)
                base += bytes.count + 1
            }
            let page = String(decoding: paper.units, as: UTF8.self)
            let index = try ProsePaperIndex(paragraphs: paragraphs, pages: [page], occurrences: hits)
            for hit in hits {
                for long in [false, true] {
                    let spans = try index.spans(for: [hit], longSentence: long)
                    if spans.isEmpty && !unique { continue }
                    guard spans.count == 1, paper.covers(spans[0], source: hit.sourceRange) else {
                        Issue.record(
                            "seed=\(seed) paragraphs=\(paragraphs) page=\(page.debugDescription) hit=\(hit) long=\(long) spans=\(spans)"
                        )
                        return
                    }
                }
            }
        }
    }
}
