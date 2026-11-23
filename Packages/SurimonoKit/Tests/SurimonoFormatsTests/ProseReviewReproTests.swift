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

@Suite("本文の取り出し・二回目のレビュー", .timeLimit(.minutes(1)))
struct ProseSecondReviewTests {
    @Test("定義にもある最初の文字は、強調した本文の行を指す")
    func definitionPosition() throws {
        let paragraph = try #require(ProseSource.markdown("[x]: /url\n*x*").paragraphs.first)
        #expect(paragraph.text == "x")
        #expect(paragraph.lines == 2...2)
        #expect(paragraph.sourceRange(of: 0..<1) == 11..<12)
    }

    @Test("複数行の題と属性の参照定義が続いても、本文の先頭を選ぶ")
    func consecutiveDefinitions() throws {
        let paragraph = try #require(
            ProseSource.markdown("[x]: /url\n    \"title\"\n^[x]: color\n*x*").paragraphs.first)
        #expect(paragraph.text == "x")
        #expect(paragraph.sourceRange(of: 0..<1) == 35..<36)
        #expect(paragraph.lines == 4...4)
    }

    @Test("隣り合う文字参照は、それぞれの展開全体がその参照を指す")
    func adjacentEntities() throws {
        let paragraph = try #require(ProseSource.markdown("&fjlig;&#65;Z").paragraphs.first)
        #expect(paragraph.text == "fjAZ")
        #expect(paragraph.sourceRange(of: 0..<1) == 0..<7)
        #expect(paragraph.sourceRange(of: 1..<2) == 0..<7)
        #expect(paragraph.sourceRange(of: 2..<3) == 7..<12)
        #expect(paragraph.sourceRange(of: 3..<4) == 12..<13)
    }

    @Test("リンク先と同じ通常リンクのラベルを読み、山括弧のアドレスだけを除く")
    func linkSyntax() throws {
        let paragraph = try #require(ProseSource.markdown("[guide](guide) <a@b.org>").paragraphs.first)
        #expect(paragraph.text == "guide \u{FFFC}")
        #expect(paragraph.sourceRange(of: 0..<5) == 1..<6)
        #expect(paragraph.sourceRange(of: 6..<7) == 15..<24)
    }

    @Test("復号すると裸の URL になるときも句点を残す")
    func decodedAddress() throws {
        let paragraph = try #require(ProseSource.markdown("See https&#58;//example.org.").paragraphs.first)
        #expect(paragraph.text == "See \u{FFFC}.")
        #expect(paragraph.sourceRange(of: 4..<5) == 4..<27)
        #expect(paragraph.sourceRange(of: 5..<6) == 27..<28)
    }

    @Test("参照されず印刷されない脚注は点検しない")
    func unusedNote() throws {
        #expect(try ProseSource.markdown("本文です。\n\n[^unused]: 設定をを変更する。").paragraphs.map(\.text) == ["本文です。"])
    }

    @Test("脚注は最初に参照した順に読み、注から参照した注は末尾に一度だけ読む")
    func noteOrder() throws {
        let source = "Body[^b][^a].\n\n[^c]: Third[^b].\n[^a]: Second.\n[^b]: First[^c]."
        let paragraphs = try ProseSource.markdown(source).paragraphs
        #expect(paragraphs.map(\.text) == ["Body.", "First.", "Second.", "Third."])
        #expect(paragraphs.map(\.lines) == [1...1, 5...5, 4...4, 3...3])
        #expect(paragraphs.map(\.index) == [0, 1, 2, 3])
    }

    @Test("長い段落でバックスラッシュの改行が続いても末尾の位置を求められる")
    func manyHardBreaks() throws {
        let paragraph = try #require(
            ProseSource.markdown(String(repeating: "a\\\n", count: 32_000) + "Z").paragraphs.first)
        #expect(paragraph.sourceRange(of: 64_000..<64_001) == 96_000..<96_001)
    }

    @Test("多数の短い段落を順に集められる")
    func manyParagraphs() throws {
        let paragraphs = try ProseSource.markdown(String(repeating: "a\n\n", count: 155_000)).paragraphs
        #expect(paragraphs.count == 155_000)
        #expect(paragraphs.last?.sourceRange == 464_997..<464_998)
    }

    @Test("裸の URL の書記素境界と末尾の句読点で変換 HTML のバイト列を保つ")
    func converterBytes() {
        let cases = [
            (
                "See https://example.org/\u{0600}&bogus;",
                "<p>See <a href=\"https://example.org/\u{0600}&amp;bogus;\">https://example.org/\u{0600}&amp;bogus;</a></p>\n"
            ),
            (
                "See https://example.org/a(b)). Then www.example.org!",
                "<p>See <a href=\"https://example.org/a(b)\">https://example.org/a(b)</a>). Then <a href=\"http://www.example.org\">www.example.org</a>!</p>\n"
            ),
        ]
        for (source, expected) in cases {
            #expect(Array(MarkdownConverter.convert(source).body.utf8) == Array(expected.utf8))
        }
    }

    @Test("本文の外の指定は両端を本文の境界に丸める")
    func clampedRange() throws {
        let paragraph = try #require(ProseSource.plainText("abc").paragraphs.first)
        #expect(paragraph.sourceRange(of: -1..<1) == 0..<1)
        #expect(paragraph.sourceRange(of: -5 ..< -2) == 0..<0)
        #expect(paragraph.sourceRange(of: 2..<10) == 2..<3)
        #expect(paragraph.sourceRange(of: 9..<12) == 3..<3)
    }
}

extension ProseSecondReviewTests {
    @Test("一つのテキストノード内で文字参照を復号中にも取り消しを確認する")
    func cancelDecoding() async {
        let units = Array(String(repeating: "&amp;", count: 8_000).utf16)
        let stopped = await Task {
            var emitted = 0
            let completed = ProseTextDecoding.scan(
                units, range: 0..<40_000, literal: Array(repeating: 38, count: 8_000)
            ) { _, _ in
                emitted += 1
                if emitted == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return !completed && emitted < 1_000
        }.value
        #expect(stopped)
    }
}
