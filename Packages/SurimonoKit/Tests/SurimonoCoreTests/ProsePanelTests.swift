import Foundation
import Testing

@testable import SurimonoCore

struct ProsePanelTests {
    @Test("原文の何番目の重複かを数えて改行とページを越えた紙面の位置を返す")
    func ordinal() throws {
        let paragraphs = ["😀 I read the the letter.", "Then the the bell rang."]
        var index = try ProsePaperIndex(
            paragraphs: paragraphs, pages: ["😀 I read the\nthe letter.\nThen the", "the bell rang."])
        let occurrence = ProseOccurrence(paragraph: 1, sourceRange: 0..<0, textRange: 5..<12)
        let result = try index.spans(for: [occurrence])
        #expect(result.map(\.page) == [0, 1])
        #expect(result.map(\.text) == ["the", "the"])
        #expect(result.last?.range == NSRange(location: 0, length: 3))
    }

    @Test("見出しに同じ語が増えた場合も本文の語が別の場所に移った場合も印を付けない")
    func ambiguous() throws {
        let occurrence = ProseOccurrence(paragraph: 0, sourceRange: 0..<0, textRange: 4..<8)
        for paper in ["word\nThe word I read.", "No word at all.", "The wo rd I read."] {
            var index = try ProsePaperIndex(paragraphs: ["The word I read."], pages: [paper])
            #expect(try index.spans(for: [occurrence]).isEmpty)
        }
    }

    @Test("紙面の別の単語の一部を独立した原文の語と取り違えない")
    func wordBoundary() throws {
        var index = try ProsePaperIndex(paragraphs: ["the the"], pages: ["the theatre"])
        let occurrence = ProseOccurrence(paragraph: 0, sourceRange: 0..<7, textRange: 0..<7)
        #expect(try index.spans(for: [occurrence]).isEmpty)
    }

    @Test("近い繰り返しの全箇所がそろうときだけ印を返す")
    func allOccurrences() throws {
        let text = "青い花と白い花と赤い花。"
        let occurrences = [2, 6, 10].map { ProseOccurrence(paragraph: 0, sourceRange: 0..<0, textRange: $0..<($0 + 1)) }
        var ok = try ProsePaperIndex(paragraphs: [text], pages: ["青い花と白\nい花と赤い花。"])
        #expect(try ok.spans(for: occurrences).map(\.range.location) == [2, 7, 11])
        var missing = try ProsePaperIndex(paragraphs: [text], pages: ["青い花と白い布と赤い花。"])
        #expect(try missing.spans(for: occurrences).isEmpty)
    }

    @Test("指摘は種類順にまとまり各組の中は原文の順を保つ")
    func groups() throws {
        let text = "We read the the letter. We saw a a bird."
        let report = try ProsePanelReport(report: ProseTesting.report(text), pages: [text])
        #expect(ProsePanelReport.Group.allCases == [.duplicate, .repetition, .longSentence])
        #expect(report.groups.keys.count == 1)
        #expect(report.groups[.duplicate]?.map(\.excerpt) == ["the the letter. We saw a a bird.", "a a bird."])
    }

    @Test("合計30件までは開き31件からはたたむ", arguments: [30, 31])
    func threshold(count: Int) throws {
        let text = Array(repeating: "We read the the letter.", count: count).joined(separator: "\n\n")
        let panel = try ProsePanelReport(report: ProseTesting.report(text), pages: [text])
        #expect(panel.groups[.duplicate]?.count == count)
        #expect(panel.initiallyExpanded == (count == 30))
    }

    @Test("抜粋は文字を壊さず改行を詰めて末尾だけを省く")
    func excerpt() {
        let text = "前置き😀\n白い紙" + String(repeating: "あ", count: 140)
        let excerpt = ProsePanelReport.excerpt(in: text, at: 3..<5)
        #expect(excerpt.hasPrefix("😀 白い紙"))
        #expect(excerpt.hasSuffix("…"))
        #expect(!excerpt.contains("前置き"))
    }

    @Test("印は同じページと組版で表示している間だけ保ち閉じた後や検索の後に復活しない")
    func lifetime() {
        let span = ProsePaperSpan(page: 1, range: NSRange(location: 1, length: 2), text: "紙面")
        for (open, generation, page) in [(false, 7, 0), (true, 8, 0), (true, 7, 2)] {
            var mark = ProsePaperMark()
            mark.select([span], generation: 7, readingPage: 0)
            mark.update(presented: true, generation: 7, readingPage: 0)
            #expect(mark.spans == [span])
            mark.update(presented: open, generation: generation, readingPage: page)
            mark.update(presented: true, generation: 7, readingPage: 0)
            #expect(mark.spans.isEmpty)
        }
        var mark = ProsePaperMark()
        mark.select([span], generation: 7, readingPage: 0)
        mark.dismiss()
        #expect(mark.spans.isEmpty)
    }
}
