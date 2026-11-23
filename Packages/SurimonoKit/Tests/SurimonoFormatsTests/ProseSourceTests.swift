import Foundation
import Testing

@testable import SurimonoFormats

@Suite("文章の本文の取り出し")
struct ProseSourceTests {
    private func texts(_ markdown: String) -> [String] { ProseSource.markdown(markdown).paragraphs.map(\.text) }

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
        let source = ProseSource.markdown("---\ntitle: 題名です\nlang: ja\n---\n\n本文です。\n")
        let paragraph = try #require(source.paragraphs.first)
        #expect(source.paragraphs.count == 1)
        #expect(paragraph.text == "本文です。")
        #expect(paragraph.lines == 6...6)
    }

    @Test("箇条書きの印とタスクの印は本文に入らない")
    func listMarkers() {
        #expect(texts("- 一つ目の項目\n- [x] 済んだ項目\n\n1. 番号の項目\n   続きの行\n") == ["一つ目の項目", "済んだ項目", "番号の項目\n   続きの行"])
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
            texts("これは**重要な**文で、[リンク](https://example.com/a \"題\")と<span>タグ</span>と脚注[^1]と~~取り消し~~と _斜体_ です。")
                == ["これは重要な文で、リンクとタグと脚注と取り消しと 斜体 です。"])
    }

    @Test("参照リンクのラベルと画像の印は消える")
    func referenceLinks() {
        #expect(texts("詳しくは[手引き][guide]と![図の説明](a.png)を見る。\n\n[guide]: https://example.com\n") == ["詳しくは手引きと図の説明を見る。"])
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
        let paragraph = try #require(ProseSource.markdown(markdown).paragraphs.first)
        let text = paragraph.text as NSString
        let word = text.range(of: "重要な")
        #expect(slice(markdown, paragraph.sourceRange(of: word.location..<(word.location + word.length))) == "重要な")
        // A range across markup takes the markup in: it is one stretch of the source.
        let across = text.range(of: "は重要な文")
        #expect(
            slice(markdown, paragraph.sourceRange(of: across.location..<(across.location + across.length)))
                == "は**重要な**文")
        let code = text.range(of: "\u{FFFC}")
        #expect(slice(markdown, paragraph.sourceRange(of: code.location..<(code.location + 1))) == "`code`")
        #expect(slice(markdown, paragraph.sourceRange) == "これは**重要な**文で、`code` を使う。")
    }

    @Test("絵文字や結合文字があっても範囲は UTF-16 でずれない")
    func utf16Offsets() throws {
        let markdown = "- 😀 か\u{3099}ぎの**設定**を見る\r\n- 次の項目\r\n"
        let paragraph = try #require(ProseSource.markdown(markdown).paragraphs.first)
        let word = (paragraph.text as NSString).range(of: "設定")
        #expect(slice(markdown, paragraph.sourceRange(of: word.location..<(word.location + word.length))) == "設定")
        #expect(ProseSource.markdown(markdown).paragraphs.map(\.lines) == [1...1, 2...2])
    }

    @Test("プレーンテキストは空行で段落に分かれ、URL だけが置き物になる")
    func plainText() throws {
        let text = "一行目です。\n二行目は https://example.com です。\n\n　\n次の段落 with *stars*.\n"
        let source = ProseSource.plainText(text)
        #expect(source.kind == .plainText)
        #expect(source.paragraphs.map(\.text) == ["一行目です。\n二行目は \u{FFFC} です。", "次の段落 with *stars*."])
        #expect(source.paragraphs.map(\.lines) == [1...2, 5...5])
        #expect(slice(text, try #require(source.paragraphs.last).sourceRange) == "次の段落 with *stars*.")
    }

    @Test("読まない形式では本文を返さない")
    func unsupportedFormats() {
        #expect(ProseSource(text: "<p>本文</p>", format: .html) == nil)
        #expect(ProseSource(text: "本文です。", format: .markdown)?.kind == .markdown)
        #expect(ProseSource(text: "本文です。", format: .plainText)?.kind == .plainText)
    }

    @Test("20 万字の段落 1 つでも、印だらけの文書でも、すぐに終わる", .timeLimit(.minutes(1)))
    func largeInputs() {
        let clock = ContinuousClock()
        let single = String(repeating: "設定を**変更**すると `code` が動く。", count: 10_000)
        let marks = String(repeating: "*[`$\\(", count: 30_000)
        let elapsed = clock.measure {
            #expect(ProseSource.markdown(single).paragraphs.count == 1)
            _ = ProseSource.markdown(marks)
        }
        #expect(elapsed < .seconds(10))
    }
}
