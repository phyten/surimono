import Testing

@testable import SurimonoCore

@Suite("文書の構造")
struct DocumentOutlineTests {
    @Test("HTML から見出しの深さ・文字・ID を読む")
    func readsHeadings() {
        let html = #"<h1 id="a">はじめに</h1><p>本文</p><h2>開館の<em>手順</em></h2>"#
        #expect(
            DocumentOutline.headings(inHTML: html) == [
                DocumentHeading(level: 1, text: "はじめに", id: "a"), DocumentHeading(level: 2, text: "開館の手順"),
            ])
    }

    @Test("ルビの読みは見出しの文字に入れない")
    func dropsRubyText() {
        let html = "<h1><ruby>図書室<rp>(</rp><rt>としょしつ</rt><rp>)</rp></ruby>の手引き</h1>"
        #expect(DocumentOutline.headings(inHTML: html).first?.text == "図書室の手引き")
    }

    @Test("見出しは前から順にページを探す")
    func searchesForward() {
        let headings = [DocumentHeading(level: 1, text: "はじめに"), DocumentHeading(level: 1, text: "本の探し方")]
        let pages = ["はじめに\n本文", "ほかの本文\n本の探し方", "本の探し方の続き"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [0, 1])
    }

    @Test("本文の中で引いた見出しの言葉には反応しない")
    func ignoresQuotedHeading() {
        let headings = [DocumentHeading(level: 1, text: "本の探し方")]
        let pages = ["「本の探し方」を読んでください", "本の探し方\n本文"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [1])
    }

    @Test("折り返した見出しと番号の付いた見出しも見つける")
    func findsWrappedAndNumberedHeadings() {
        let headings = [DocumentHeading(level: 1, text: "長い見出しの折り返し"), DocumentHeading(level: 2, text: "節")]
        let pages = ["長い見出しの\n折り返し\n1.1 節"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [0, 0])
    }

    @Test("見つからない見出しは空にして、次を同じページから探す")
    func keepsSearchingAfterMissingHeading() {
        let headings = [DocumentHeading(level: 1, text: "ない"), DocumentHeading(level: 1, text: "ある")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["ある"]) == [nil, 0])
    }

    @Test("文字数はタグと空白を数えない")
    func countsCharacters() {
        #expect(DocumentStatistics(html: "<p>星見 図書室</p>\n<p>a&amp;b</p>").characters == 8)
    }

    @Test("行末で触れた見出しの言葉には反応しない")
    func ignoresMentionAtLineEnd() {
        let headings = [DocumentHeading(level: 1, text: "本の探し方")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["次に説明するのは本の探し方", "本の探し方\n本文"]) == [1])
    }

    @Test("同じ名前の見出しはそれぞれのページに対応する")
    func matchesRepeatedHeadings() {
        let headings = [DocumentHeading(level: 2, text: "まとめ"), DocumentHeading(level: 2, text: "まとめ")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["まとめ\n本文", "まとめ\n本文"]) == [0, 1])
    }

    @Test("同じページの見出しを順に見つける")
    func findsHeadingsOnOnePage() {
        let headings = [DocumentHeading(level: 2, text: "一つ目"), DocumentHeading(level: 2, text: "一つ目")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["一つ目\n本文\n一つ目"]) == [0, 0])
    }

    @Test("コメントの中の見出しは読まない")
    func skipsComments() {
        #expect(DocumentOutline.headings(inHTML: "<!-- <h1>隠す</h1> --><h1>本文</h1>").map(\.text) == ["本文"])
    }

    @Test("属性の中の > で見出しの文字が崩れない")
    func readsQuotedAttributes() {
        let heading = DocumentOutline.headings(inHTML: #"<h1 title="a > b" data-id="wrong" id='right'>見出し</h1>"#).first
        #expect(heading == DocumentHeading(level: 1, text: "見出し", id: "right"))
    }

    @Test("複数行のスタイルと SVG は文字数に入れない")
    func skipsMultilineStyle() {
        let html =
            "<p>本文</p><style>\n@font-face { src: url(data:font/woff2;base64,AAAA); }\n</style><svg>\n<text>x</text>\n</svg>"
        #expect(DocumentStatistics(html: html).characters == 2)
    }

    @Test("文字の参照は一度だけ解く")
    func decodesEntitiesOnce() {
        #expect(DocumentOutline.plainText(ofHTML: "&#x65E5;&#26412;&copy;&amp;lt;") == "日本©&lt;")
    }

    @Test("読む時間は 1 分に 500 字で数え、文字があれば 1 分以上にする")
    func estimatesReadingTime() {
        #expect(DocumentStatistics(characters: 0).readingMinutes == 0)
        #expect(DocumentStatistics(characters: 10).readingMinutes == 1)
        #expect(DocumentStatistics(characters: 1784).readingMinutes == 4)
    }
}
