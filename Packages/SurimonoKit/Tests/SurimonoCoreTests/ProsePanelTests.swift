import Foundation
import Testing

@testable import SurimonoCore

struct ProsePanelTests {
    private func occurrence(_ range: Range<Int>, paragraph: Int = 0) -> ProseOccurrence {
        ProseOccurrence(
            paragraph: paragraph, sourceRange: range, textRange: range, sentenceRange: range, isEnglish: true)
    }

    @Test("原文の何番目の重複かを数えて改行とページを越えた紙面の位置を返す")
    func ordinal() throws {
        let paragraphs = ["😀 I read the the letter.", "Then the the bell rang."]
        var index = try ProsePaperIndex(
            paragraphs: paragraphs, pages: ["😀 I read the\nthe letter.\nThen the", "the bell rang."])
        let occurrence = occurrence(5..<12, paragraph: 1)
        let result = try index.spans(for: [occurrence])
        #expect(result.map(\.page) == [0, 1])
        #expect(result.map(\.text) == ["the", "the"])
        #expect(result.last?.range == NSRange(location: 0, length: 3))
    }

    @Test("見出しに同じ語が増えた場合も本文の語が別の場所に移った場合も印を付けない")
    func ambiguous() throws {
        let occurrence = occurrence(4..<8)
        for paper in ["word\nThe word I read.", "No word at all.", "The wo rd I read."] {
            var index = try ProsePaperIndex(paragraphs: ["The word I read."], pages: [paper])
            #expect(try index.spans(for: [occurrence]).isEmpty)
        }
    }

    @Test("紙面の別の単語の一部を独立した原文の語と取り違えない")
    func wordBoundary() throws {
        var index = try ProsePaperIndex(paragraphs: ["the the"], pages: ["the theatre"])
        let occurrence = occurrence(0..<7)
        #expect(try index.spans(for: [occurrence]).isEmpty)
    }

    @Test("近い繰り返しの全箇所がそろうときだけ印を返す")
    func allOccurrences() throws {
        let text = "青い花と白い花と赤い花。"
        let occurrences = [2, 6, 10].map { occurrence($0..<($0 + 1)) }
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
        #expect(report.groups[.duplicate]?.map(\.excerpt.text) == ["We read the the letter.", "We saw a a bird."])
    }

    @Test("合計30件までは開き31件からはたたむ", arguments: [30, 31])
    func threshold(count: Int) throws {
        let text = Array(repeating: "We read the the letter.", count: count).joined(separator: "\n\n")
        let panel = try ProsePanelReport(report: ProseTesting.report(text), pages: [text])
        #expect(panel.groups[.duplicate]?.count == count)
        #expect(panel.initiallyExpanded == (count == 30))
    }

    private let source = """
        As I traced the pencil line from the village to the river and followed the narrow path beside \
        the old mill, I wondered how the person who drew this map had managed to capture so \
        many small details on a single sheet of paper.
        """
    // PDFKit's text from a Quartz PDF with the same three lines as the sample window.
    private let extracted = """
        As I traced the pencil line from the vilage to the river and folowed the narrow path beside
        the old mil, I wondered how the person who drew this map had managed to capture so
        many smal details on a single sheet of paper.
        """

    @Test("英語見本の44語が折り返され細い小文字のエルが重なって抽出されても元のPDF範囲を選ぶ")
    func wrappedEnglish() throws {
        let page = "Map\n" + extracted
        let report = try ProseTesting.report(source)
        let panel = try ProsePanelReport(report: report, pages: [page])
        let row = try #require(panel.groups[.longSentence]?.first)
        #expect(row.kind == .longSentence(length: 44, unit: .words))
        #expect(
            row.spans == [
                ProsePaperSpan(page: 0, range: NSRange(location: 4, length: extracted.utf16.count), text: extracted)
            ])
    }

    @Test("同じ英文の候補が余る場合やエル以外の文字が違う場合は選ばない")
    func ambiguousEnglishSentence() throws {
        let report = try ProseTesting.report(source)
        let page = "Map\n" + extracted
        for ambiguous in [[page, page], [page, source], [page.replacingOccurrences(of: "river", with: "rider")]] {
            let panel = try ProsePanelReport(report: report, pages: ambiguous)
            #expect(panel.groups[.longSentence]?.first?.spans.isEmpty == true)
        }
    }

    @Test("紙面の細いエルが重なっても同じ全文が二度あれば原文の順に選ぶ")
    func repeatedEnglishSentence() throws {
        let page = "Map\n" + extracted
        let twice = try ProseTesting.report(source + "\n\n" + source)
        let repeated = try ProsePanelReport(report: twice, pages: [page, page])
        #expect(repeated.groups[.longSentence]?.map { $0.spans.first?.page } == [0, 1])
    }

    @Test("抜粋は文頭では省かず文の途中では日本語は直前4文字と英語は直前2語を残す")
    func excerptContext() throws {
        for (sentence, hit, english, prefix, suffix) in [
            ("をを見た。", "をを", false, "", "見た。"),
            ("朝の小さな青い花をを見た。", "をを", false, "…な青い花", "見た。"),
            ("The the ink dried.", "The the", true, "", " ink dried."),
            ("After lunch I laid the the letter.", "the the", true, "…I laid ", " letter."),
        ] {
            let paragraph = "先の文。" + sentence + "次の文。"
            let text = paragraph as NSString
            let range = try #require(Range(text.range(of: hit)))
            let sentenceRange = try #require(Range(text.range(of: sentence)))
            let occurrence = ProseOccurrence(
                paragraph: 0, sourceRange: range, textRange: range, sentenceRange: sentenceRange, isEnglish: english)
            let excerpt = ProseExcerpt(paragraph: paragraph, occurrence: occurrence)
            #expect(excerpt.before == prefix)
            #expect(excerpt.place == hit)
            #expect(excerpt.after == suffix)
        }
    }

    @Test("日本語の抜粋は絵文字を丸ごと残し改行を詰めて末尾を省く")
    func excerptBoundaries() {
        let paragraph = "前置き😀\n白い紙" + String(repeating: "あ", count: 140)
        let occurrence = ProseOccurrence(
            paragraph: 0, sourceRange: 3..<5, textRange: 3..<5, sentenceRange: 0..<paragraph.utf16.count,
            isEnglish: false)
        let excerpt = ProseExcerpt(paragraph: paragraph, occurrence: occurrence)
        #expect(excerpt.before == "前置き")
        #expect(excerpt.place == "😀")
        #expect(excerpt.after.hasPrefix(" 白い紙"))
        #expect(excerpt.after.hasSuffix("…"))
    }

    @Test("印は同じページと組版で表示している間だけ保ち閉じた後や検索の後に復活しない")
    func lifetime() {
        let span = ProsePaperSpan(page: 1, range: NSRange(location: 1, length: 2), text: "紙面")
        for (open, generation, page) in [(false, 7, 0), (true, 8, 0), (true, 7, 2)] {
            var mark = ProsePaperMark()
            mark.select([span], findingID: 1, generation: 7, readingPage: 0)
            mark.update(presented: true, generation: 7, readingPage: 0)
            #expect(mark.spans == [span])
            mark.update(presented: open, generation: generation, readingPage: page)
            mark.update(presented: true, generation: 7, readingPage: 0)
            #expect(mark.spans.isEmpty)
        }
        var mark = ProsePaperMark()
        mark.select([span], findingID: 1, generation: 7, readingPage: 0)
        mark.dismiss()
        #expect(mark.spans.isEmpty)
        #expect(mark.findingID == nil)
    }
}
