import Foundation
import Testing

@testable import SurimonoFormats

extension ProseSource {
    /// The tests here are never cancelled, so reading cannot throw.
    static func ofMarkdown(_ text: String) -> ProseSource {
        (try? markdown(text)) ?? ProseSource(kind: .markdown, paragraphs: [])
    }

    static func ofPlainText(_ text: String) -> ProseSource {
        (try? plainText(text)) ?? ProseSource(kind: .plainText, paragraphs: [])
    }
}

@Suite("文章の本文の取り出し", .timeLimit(.minutes(1)))
struct ProseSourceTests {
    private func texts(_ markdown: String) -> [String] { ProseSource.ofMarkdown(markdown).paragraphs.map(\.text) }

    private func slice(_ source: String, _ range: Range<Int>) -> String {
        (source as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    @Test("段落だけを本文として取り出し、見出しは取り出さない")
    func paragraphsOnly() {
        #expect(texts("# 見出しです\n\n最初の段落です。\n\n二つ目の段落です。\n\n副題\n----\n") == ["最初の段落です。", "二つ目の段落です。"])
    }

    @Test("コードブロック・字下げのコード・HTML ブロック・表・引用は取り出さない")
    func excludedBlocks() {
        let markdown = """
            本文です。

            ```swift
            let code = 1
            ```

                indented code

            <div>HTML のブロックです</div>

            | 列 | 値 |
            |---|---|
            | セル | 1 |

            > 引用の文です。

            > [!note]
            > 囲みの文です。

            終わりの文です。
            """
        #expect(texts(markdown) == ["本文です。", "終わりの文です。"])
    }

    @Test("front matter は取り出さず、行の番号は front matter を含めて数える")
    func frontMatter() throws {
        let source = ProseSource.ofMarkdown("---\ntitle: 題名です\nlang: ja\n---\n\n本文です。\n")
        let paragraph = try #require(source.paragraphs.first)
        #expect(source.paragraphs.count == 1)
        #expect(paragraph.text == "本文です。")
        #expect(paragraph.lines == 6...6)
    }

    @Test("箇条書きの印とタスクの印は本文に入らない")
    func listMarkers() {
        #expect(texts("- 一つ目の項目\n- [x] 済んだ項目\n\n1. 番号の項目\n   続きの行\n") == ["一つ目の項目", "済んだ項目", "番号の項目\n続きの行"])
    }

    @Test("インラインのコード・数式・URL は 1 つの置き物になる")
    func shownButNotProse() {
        #expect(
            texts("設定は `config.json` と $x^2$ と https://example.com/a を見る。") == [
                "設定は \u{FFFC} と \u{FFFC} と \u{FFFC} を見る。"
            ])
    }

    @Test("強調・リンク・タグ・脚注の印は消え、中の文字は残る")
    func droppedMarkup() {
        #expect(
            texts(
                "これは**重要な**文で、[リンク](https://example.com/a \"題\")と<span>タグ</span>と脚注[^1]と~~取り消し~~と _斜体_ です。\n\n[^1]: 注です。\n"
            )
                == ["これは重要な文で、リンクとタグと脚注と取り消しと 斜体 です。", "注です。"])
    }

    @Test("参照リンクのラベルは消え、画像は代わりの文字ごと 1 つの置き物になる")
    func referenceLinks() {
        #expect(
            texts("詳しくは[手引き][guide]と![図の説明](a.png)を見る。\n\n[guide]: https://example.com\n") == ["詳しくは手引きと\u{FFFC}を見る。"])
    }

    @Test("ルビは親文字だけが残る")
    func ruby() {
        #expect(texts("{漢字|かんじ}を読む。") == ["漢字を読む。"])
    }

    @Test("単語の中の下線は残る")
    func underscoreInsideWord() {
        #expect(texts("snake_case の名前です。") == ["snake_case の名前です。"])
    }

    @Test("値段のドルは数式にならない")
    func dollars() {
        #expect(texts("$5 と $10 を払う。") == ["$5 と $10 を払う。"])
    }

    @Test("囲みの行は段落を分け、本文に入らない")
    func containers() {
        #expect(texts("前の文です。\n::: note\n囲みの中です。\n:::\n後の文です。\n") == ["前の文です。", "囲みの中です。", "後の文です。"])
    }

    @Test("目次の印と文字のない段落は取り出さない")
    func nothingToRead() {
        #expect(texts("[TOC]\n\n`code`\n\nhttps://example.com\n\n本文です。\n") == ["本文です。"])
    }

    @Test("本文の範囲から原文の範囲へ戻せる")
    func sourceRanges() throws {
        let markdown = "# 題\n\nこれは**重要な**文で、`code` を使う。\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.first)
        #expect(paragraph.sourceRange(of: 3..<6) == 10..<13)
        // One source stretch includes any intervening markup.
        #expect(paragraph.sourceRange(of: 2..<7) == 7..<16)
        #expect(paragraph.sourceRange(of: 9..<10) == 18..<24)
        #expect(slice(markdown, paragraph.sourceRange) == "これは**重要な**文で、`code` を使う。")
    }

    @Test("絵文字や結合文字があっても範囲は UTF-16 でずれない")
    func utf16Offsets() throws {
        let markdown = "- 😀 か\u{3099}ぎの**設定**を見る\r\n- 次の項目\r\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.first)
        #expect(paragraph.sourceRange(of: 7..<9) == 11..<13)
        #expect(ProseSource.ofMarkdown(markdown).paragraphs.map(\.lines) == [1...1, 2...2])
    }

    @Test("改行の印のあとでも、リストの中でも、語は原文の同じ語へ戻る")
    func positionsAfterHardBreaks() throws {
        let markdown =
            "前置き。\n\n- 一行目\\\n  二行目 *強調*  \n  三行目 `c`\\\n  四行目 &amp; ![alt](a.png) <b>太字</b>\\\n  五行目\n  六行目 **終わり**\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.last)
        #expect(paragraph.text == "一行目\n二行目 強調\n三行目 \u{FFFC}\n四行目 & \u{FFFC} 太字\n五行目\n六行目 終わり")
        #expect(paragraph.lines == 3...8)
        for (visible, source) in [
            (0..<3, 8..<11), (4..<7, 15..<18), (8..<10, 20..<22), (11..<14, 28..<31),
            (17..<20, 39..<42), (25..<27, 66..<68), (28..<31, 76..<79), (32..<35, 82..<85),
            (36..<39, 88..<91), (23..<24, 49..<62), (21..<22, 43..<48),
        ] {
            #expect(paragraph.sourceRange(of: visible) == source)
        }
    }

    @Test("CRLF の入れ子のリストの 2 行目で、絵文字・結合文字・タブのあとの語の位置が合う")
    func absoluteRangeOnSecondLine() throws {
        let markdown = "- 親\r\n  - 😀 か\u{3099}ぎと\r\n    \tの**設定**を `x` 見る\r\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.last)
        #expect(paragraph.text == "😀 か\u{3099}ぎと\nの設定を \u{FFFC} 見る")
        #expect(paragraph.sourceRange(of: 9..<11) == 26..<28)
        #expect(paragraph.sourceRange(of: 13..<14) == 32..<35)
        #expect(paragraph.lines == 2...3)
    }

    @Test("複数行のコードスパンとリンクのあとでも位置が合う")
    func positionsAfterMultilineInlines() throws {
        let markdown = "始め `a\nb` 中 [リンク](https://example.com\n\"題\") 終わり\\\n次の行 *x*\n"
        let paragraph = try #require(ProseSource.ofMarkdown(markdown).paragraphs.first)
        #expect(paragraph.text == "始め \u{FFFC} 中 リンク 終わり\n次の行 x")
        for (visible, source) in [
            (5..<6, 9..<10), (7..<10, 12..<15), (11..<14, 42..<45), (15..<18, 47..<50), (19..<20, 52..<53),
        ] {
            #expect(paragraph.sourceRange(of: visible) == source)
        }
    }

    @Test("コードの両側の同じ語は、置き物をはさんで残る")
    func wordsAroundCode() {
        #expect(texts("Use the `x` the same way.") == ["Use the \u{FFFC} the same way."])
    }

    @Test("HTML の code の中身は置き物になり、ruby の読みは消える")
    func rawHTML() {
        #expect(
            texts("値は <kbd>Ctrl</kbd> と <ruby>漢字<rt>かんじ</rt></ruby> と<br>改行 <img src=\"a.png\"> です。")
                == ["値は \u{FFFC} と 漢字 と 改行 \u{FFFC} です。"])
    }

    @Test("定義リストは語と説明が別々の段落になり、説明の印は入らない")
    func definitionLists() {
        #expect(texts("用紙\n: 紙の説明。\n: 二つ目の説明。\n") == ["用紙", "紙の説明。", "二つ目の説明。"])
        #expect(texts("用紙\n余白\n\n: 紙の説明。\n  続きの行。\n\n: 次の説明。\n") == ["用紙", "余白", "紙の説明。\n続きの行。", "次の説明。"])
        #expect(texts(": 語のない行はそのまま。\n") == [": 語のない行はそのまま。"])
    }

    @Test("脚注の本文は印なしの別の段落になり、複数行の数式ブロックは読まない")
    func footnotesAndDisplayMath() throws {
        let markdown = "本文[^a]です。\n\n[^a]: 注の一行目。\n    注の二行目 **強調**。\n\n- 項目\n\n  $$\n  x + y\n  $$\n\n  続きの文。\n"
        let source = ProseSource.ofMarkdown(markdown)
        #expect(source.paragraphs.map(\.text) == ["本文です。", "項目", "続きの文。", "注の一行目。\n注の二行目 強調。"])
        let note = try #require(source.paragraphs.last)
        #expect(note.lines == 3...4)
        #expect(note.sourceRange(of: 13..<15) == 36..<38)
        #expect(slice(markdown, note.sourceRange) == "注の一行目。\n    注の二行目 **強調**。")
    }

    @Test("取り消したタスクでは読み取りをやめる")
    func cancellation() async {
        let text = String(repeating: "本文です。\n\n", count: 2000)
        let task = Task { () -> Int in
            await Task.yield()
            return try ProseSource.markdown(text).paragraphs.count + ProseSource.plainText(text).paragraphs.count
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("プレーンテキストは空行で段落に分かれ、URL だけが置き物になる")
    func plainText() throws {
        let text = "一行目です。\n二行目は https://example.com です。\n\n　\n次の段落 with *stars*.\n"
        let source = ProseSource.ofPlainText(text)
        #expect(source.kind == .plainText)
        #expect(source.paragraphs.map(\.text) == ["一行目です。\n二行目は \u{FFFC} です。", "次の段落 with *stars*."])
        #expect(source.paragraphs.map(\.lines) == [1...2, 5...5])
        #expect(slice(text, try #require(source.paragraphs.last).sourceRange) == "次の段落 with *stars*.")
    }

    @Test("読まない形式では本文を返さない")
    func unsupportedFormats() throws {
        #expect(try ProseSource.read("<p>本文</p>", format: .html) == nil)
        #expect(try ProseSource.read("本文です。", format: .markdown)?.kind == .markdown)
        #expect(try ProseSource.read("本文です。", format: .plainText)?.kind == .plainText)
    }

    // No time is asserted (the benchmark records times); the limit only stops a pass that has become quadratic.
    @Test("20 万字の段落 1 つも、印だらけの文書も、終わりまで読める", .timeLimit(.minutes(1)))
    func largeInputs() throws {
        let single = String(repeating: "設定を**変更**すると `code` が動く。", count: 10_000)
        let paragraph = try #require(ProseSource.ofMarkdown(single).paragraphs.first)
        #expect(paragraph.text.utf16.count == 10_000 * 15)
        #expect(paragraph.sourceRange(of: 149_988..<149_990) == 239_981..<239_983)
        _ = ProseSource.ofMarkdown(String(repeating: "*[`$\\(", count: 30_000))
    }
}
