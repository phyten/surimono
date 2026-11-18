import Foundation
import Testing

@testable import SurimonoFormats

struct CriticMarkupTests {
    @Test("校正の五つの記法を表示する")
    func shown() {
        let html = MarkdownConverter.convert("{++added++} {--deleted--} {~~old~>new~~} {==highlight==} {>>comment<<}")
            .body
        #expect(html.contains("<ins class=\"critic\">added</ins>"))
        #expect(html.contains("<del class=\"critic\">deleted</del>"))
        #expect(html.contains("<del class=\"critic\">old</del><ins class=\"critic\">new</ins>"))
        #expect(html.contains("<mark class=\"critic\">highlight</mark>"))
        #expect(html.contains("<span class=\"critic-comment\">comment</span>"))
    }

    @Test("記号だけの行で囲んだ校正も中の強調を読む")
    func marksOnTheirOwnLines() {
        let source = "{++\n**追加**\n++}"
        #expect(
            MarkdownConverter.convert(source).body == "<p><ins class=\"critic\"><strong>追加</strong></ins></p>\n")
        #expect(MarkdownConverter.convert(source, proof: .accepted).body.contains("<strong>追加</strong>"))
        #expect(
            MarkdownConverter.convert("{--\n*削除*\n--}").body
                == "<p><del class=\"critic\"><em>削除</em></del></p>\n")
    }

    @Test("記号のすぐ後ろに空白があっても強調を読み、前後の語はつながらない")
    func edgesKeepWords() {
        #expect(MarkdownConverter.convert("{++ \n**追加**\n++}").body.contains("<strong>追加</strong>"))
        let shown = MarkdownConverter.convert("one{++\ntwo\n++}three").body
        #expect(shown == "<p>one\n<ins class=\"critic\">two</ins>\nthree</p>\n")
        #expect(
            MarkdownConverter.convert("{++    \nfour spaces++} tail").body
                == "<p><ins class=\"critic\">four spaces</ins> tail</p>\n")
        #expect(MarkdownConverter.convert("a {++ b ++} c").body == "<p>a <ins class=\"critic\"> b </ins> c</p>\n")
        #expect(
            MarkdownConverter.convert("one{++two  \n++}three").body
                == "<p>one<ins class=\"critic\">two</ins><br>\nthree</p>\n")
    }

    @Test("閉じる記号の前の字下げを残し、後ろの # を見出しにしない")
    func trailingIndentStays() {
        let html = MarkdownConverter.convert("{++foo\n    ++}# Heading").body
        #expect(!html.contains("<h1"))
        #expect(html.contains("<ins class=\"critic\">foo</ins>"))
    }

    @Test("反映後と元の本文を選べる")
    func modes() {
        let source = "{++A++}{--B--}{~~C~>D~~}{==E==}{>>F<<}"
        #expect(MarkdownConverter.convert(source, proof: .accepted).body == "<p>ADE</p>\n")
        #expect(MarkdownConverter.convert(source, proof: .original).body == "<p>BCE</p>\n")
    }

    @Test("本文の強調は読みコメントは文字として扱う")
    func inner() {
        let html = MarkdownConverter.convert("{++**bold**++} {>>**plain** <b>&<<}").body
        #expect(html.contains("<ins class=\"critic\"><strong>bold</strong></ins>"))
        #expect(html.contains("**plain** &lt;b&gt;&amp;"))
        #expect(MarkdownConverter.convert("{++**bold**++}", proof: .accepted).body.contains("<strong>bold</strong>"))
    }

    @Test("コードと閉じていない記号は変えない")
    func protection() {
        let html = MarkdownConverter.convert("`{++x++}`\n\n```\n{--x--}\n```\n\n{++open").body
        #expect(html.contains("<code>{++x++}</code>"))
        #expect(html.contains("{--x--}\n</code>"))
        #expect(html.contains("{++open"))
    }

    @Test("校正のハイライトを通常のハイライトより先に読む")
    func highlight() {
        #expect(
            MarkdownConverter.convert("{==x==} ==y==").body == "<p><mark class=\"critic\">x</mark> <mark>y</mark></p>\n"
        )
    }

    @Test("見出しは紙に残る文字を使いコメントを除く")
    func headings() {
        let source = "# {++A++}{--B--}{~~C~>D~~}{==E==}{>>comment<<}"
        #expect(MarkdownConverter.convert(source).title == "ABCDE")
        #expect(MarkdownConverter.convert(source, proof: .accepted).title == "ADE")
        #expect(MarkdownConverter.convert(source, proof: .original).body.contains("id=\"bce\""))
    }

    @Test("目次とアウトラインから校正コメントを除く")
    func outline() {
        let html = MarkdownConverter.convert("[TOC]\n\n# {~~old~>new~~}{>>comment<<}").body
        #expect(DocumentOutline.headings(inHTML: html) == [DocumentHeading(level: 1, text: "oldnew", id: "oldnew")])
        #expect(DocumentOutline.sourceContentsEntries(inHTML: html) == ["oldnew"])
    }

    @Test("リンク先とHTMLとエスケープした記号を変えない")
    func moreProtection() {
        let html = MarkdownConverter.convert(
            "[link](https://example.com/{++x++}) \u{005C}{++escaped++}\n\n<div>\n{++raw++}\n</div>", proof: .accepted
        ).body
        #expect(html.contains("https://example.com/{++x++}"))
        #expect(html.contains("{++escaped++}"))
        #expect(html.contains("{++raw++}"))
    }

    @Test("脚注とソース対応付きの変換にも選んだ姿を使う")
    func mappedAndFootnote() {
        let source = "# {~~old~>new~~}\n\ntext[^a]\n\n[^a]: {++added++}{--deleted--}"
        let mapped = MarkdownConverter.convertWithSourceMap(source, proof: .original)
        #expect(mapped.fragment.title == "old")
        #expect(mapped.fragment.body.contains("deleted"))
        #expect(!mapped.fragment.body.contains("added"))
        #expect(!mapped.blocks.isEmpty)
    }

    @Test("閉じ忘れた校正記号を途中から別の記法として読まない", arguments: ["{==x==", "{~~old~>new~~", "{--x", "{>>x"])
    func unclosed(_ source: String) {
        #expect(MarkdownConverter.convert(source).body == "<p>" + HTML.escape(source) + "</p>\n")
    }

    @Test("同じ段落の改行をまたぐ校正は読み別の段落へは越えない")
    func softBreaks() {
        #expect(MarkdownConverter.convert("{++one\ntwo++}", proof: .accepted).body == "<p>one\ntwo</p>\n")
        #expect(
            MarkdownConverter.convert("> {~~old\n> text~>new\n> text~~}", proof: .accepted).body.contains(
                "<p>new\ntext</p>"))
        #expect(MarkdownConverter.convert("{++one\n\ntwo++}", proof: .accepted).body.contains("{++one"))
    }
}
