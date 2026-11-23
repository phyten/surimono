import Foundation
import Testing

@testable import SurimonoFormats

/// Inputs a review derived from the code; each failed before the reader was rebuilt on cmark's tree.
@Suite("本文の取り出し: レビューで見つかった入力")
struct ProseReviewReproTests {
    private func texts(_ markdown: String) -> [String] { ProseSource.ofMarkdown(markdown).paragraphs.map(\.text) }
    private func slice(_ source: String, _ range: Range<Int>) -> String {
        (source as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    @Test("参照の定義から始まる段落は、定義の行を本文にも行にも含めない") func m1ReferenceDefinition() throws {
        let markdown = "[guide]: /manual\nRead the guide.\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.first)
        #expect(paragraph.text == "Read the guide.")
        #expect(paragraph.lines == 2...2)
        #expect(slice(markdown, paragraph.sourceRange) == "Read the guide.")
    }

    @Test("表が直に続く段落も、本文・行・原文の範囲を持つ") func m1ParagraphBeforeTable() throws {
        let markdown = "本文です。\n| A | B |\n|---|---|\n| x | y |\n"
        let paragraphs = ProseSource.ofMarkdown(markdown).paragraphs
        #expect(paragraphs.map(\.text) == ["本文です。"])
        #expect(paragraphs.first?.lines == 1...1)
        #expect(paragraphs.first.map { slice(markdown, $0.sourceRange) } == "本文です。")
    }

    @Test("複数行の数式ブロックは本文にしない") func m2DisplayMath() {
        #expect(texts("前の文。\n\n$$\nalpha + beta\n$$\n\n後の文。\n") == ["前の文。", "後の文。"])
    }
    @Test("脚注の定義は印なしの段落になり、定義のない脚注の印は書いたまま残る") func m2Footnotes() {
        #expect(texts("本文[^n]と[^missing]。\n\n[^n]: 注の the the です。\n") == ["本文と[^missing]。", "注の the the です。"])
    }
    @Test("リストの中に字下げした ::: の行は、変換と同じくリストの本文として読む") func m2ContainerInList() {
        #expect(texts("- 項目\n  ::: note\n") == ["項目\n::: note"])
    }
    @Test("リストの外の [x] は消さない") func m2LiteralTaskMark() {
        #expect(texts("[x] is a variable.\n") == ["[x] is a variable."])
    }
    @Test("定義リストの語と説明は別の段落になる") func m2DefinitionList() { #expect(texts("用紙\n: 紙の説明。\n") == ["用紙", "紙の説明。"]) }

    @Test("文字として書いた * は残る") func m3LiteralStar() { #expect(texts("2 * 3 は 6 です。\n") == ["2 * 3 は 6 です。"]) }
    @Test("文字として書いた角括弧は残る") func m3LiteralBrackets() { #expect(texts("配列 [x] を読む。\n") == ["配列 [x] を読む。"]) }
    @Test("エスケープした * は * として残る") func m3EscapedStar() { #expect(texts("星 \\* を書く。\n") == ["星 * を書く。"]) }
    @Test("HTML の code の中身は本文にしない") func m3HTMLCode() {
        #expect(texts("Read <code>the the</code> here.\n") == ["Read \u{FFFC} here."])
    }
    @Test("文字参照は、それが表す文字になる") func m3Entity() { #expect(texts("A &amp; B を見る。\n") == ["A & B を見る。"]) }
    @Test("画像は代わりの文字ごと 1 つの置き物になる") func m3Image() {
        #expect(texts("図は ![the the](a.png) です。\n") == ["図は \u{FFFC} です。"])
    }

    @Test("裸の URL は変換と同じ所で終わり、直後の句点は文に残る") func m4URLBeforeStop() throws {
        let markdown = "See https://example.org. Next page.\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.first)
        #expect(paragraph.text == "See \u{FFFC}. Next page.")
        #expect(slice(markdown, paragraph.sourceRange(of: 4..<5)) == "https://example.org")
        #expect(slice(markdown, paragraph.sourceRange(of: 5..<6)) == ".")
        #expect(ProseSource.ofPlainText(markdown).paragraphs.first?.text == "See \u{FFFC}. Next page.")
    }
    @Test("山括弧で書いたリンク先は本文に入らない") func m4AngleDestination() {
        #expect(texts("[手引き](<my file.pdf>)を読む。\n") == ["手引きを読む。"])
    }
    @Test("URL を含む開始タグは置き物にならない") func m4OpeningTag() {
        #expect(texts("<a href=\"https://example.org\">ここ</a>を見る。\n") == ["ここを見る。"])
    }
}
