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

    @Test("見出しの中の数字を番号と取り違えない")
    func keepsNumbersInHeadings() {
        let headings = [DocumentHeading(level: 1, text: "2026年の計画")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["2025年の計画", "2026年の計画"]) == [1])
    }

    @Test("見つからない見出しが多くても同じ行を読み直さずに終わる")
    func handlesManyMissingHeadings() {
        let headings = (0..<2000).map { DocumentHeading(level: 2, text: "節\($0)の見出しはこの文書にありません") }
        let pages = Array(repeating: String(repeating: "節本文の行はここにあります\n", count: 40), count: 500)
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages).allSatisfy { $0 == nil })
    }

    @Test("似た名前の要素を見出しにしない")
    func requiresWholeTagName() {
        #expect(DocumentOutline.headings(inHTML: "<h1-note>項目</h1-note><h2>節</h2>").map(\.text) == ["節"])
    }

    @Test("ID の文字の参照を解く")
    func decodesIdentifier() {
        #expect(DocumentOutline.headings(inHTML: #"<h1 id="a&amp;b">見出し</h1>"#).first?.id == "a&b")
    }

    @Test("スタイルの中の似た閉じタグで終わらない")
    func keepsRawTextUntilItsClosingTag() {
        let html = #"<style>p::after{content:"</stylesheet>本文"}</style><p>字</p>"#
        #expect(DocumentStatistics(html: html).characters == 1)
    }

    @Test("原文の目次の行を見出しに取らない")
    func skipsSourceContents() {
        let headings = [DocumentHeading(level: 1, text: "第一章"), DocumentHeading(level: 1, text: "第二章")]
        let entries = ["第一章", "第二章"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: ["目次\n第一章\n第二章", "第一章\n本文", "第二章\n本文"], contentsEntries: entries)
                == [1, 2])
    }

    @Test("本文の後の目次でも本物の見出しを消さない")
    func keepsHeadingsBeforeSourceContents() {
        let headings = [DocumentHeading(level: 1, text: "第一章"), DocumentHeading(level: 1, text: "第二章")]
        let pages = ["第一章\n本文", "第二章\n本文", "第一章\n第二章"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["第一章", "第二章"]) == [0, 1])
    }

    @Test("短い先頭の行で折り返した見出しも見つける")
    func findsHeadingWrappedAfterShortLine() {
        let headings = [DocumentHeading(level: 1, text: "導入方法について")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["導入方法\nについて\n本文"]) == [0])
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

    @Test("PDF の文字で記号や合字が変わっても見出しのページを見つける")
    func toleratesExtractedPunctuation() {
        let headings = [DocumentHeading(level: 1, text: "冊子確認用 — ﬁeld"), DocumentHeading(level: 2, text: "Ａ４")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["冊子確認用 \u{336} field\nA4"]) == [0, 0])
    }

    @Test("見出しと見つかったページから目次の項目を作る")
    func entriesCarryPages() {
        let headings = [DocumentHeading(level: 1, text: "はじめに"), DocumentHeading(level: 2, text: "ない見出し")]
        #expect(
            DocumentOutline.entries(of: headings, inPageTexts: ["はじめに\n本文"]) == [
                OutlineEntry(level: 1, title: "はじめに", pageIndex: 0),
                OutlineEntry(level: 2, title: "ない見出し", pageIndex: nil),
            ])
    }

    @Test("今読んでいる章は、そのページまでで最後に始まった項目になる")
    func currentEntry() {
        let entries = [
            OutlineEntry(level: 1, title: "一", pageIndex: 0), OutlineEntry(level: 2, title: "ページ不明", pageIndex: nil),
            OutlineEntry(level: 1, title: "二", pageIndex: 3), OutlineEntry(level: 1, title: "三", pageIndex: 3),
        ]
        #expect(DocumentOutline.currentEntry(in: entries, page: 2) == 0)
        #expect(DocumentOutline.currentEntry(in: entries, page: 3) == 3)
        #expect(DocumentOutline.currentEntry(in: entries, page: 9) == 3)
    }

    @Test("最初の見出しより前のページでは今の章がない")
    func noCurrentEntryBeforeFirstHeading() {
        #expect(DocumentOutline.currentEntry(in: [OutlineEntry(level: 1, title: "一", pageIndex: 2)], page: 1) == nil)
    }

    @Test("複数行のスタイルとスクリプトと head は文字数に入れない")
    func countsVisibleTextOnly() {
        let html = """
            <html><head>
            <title>題</title>
            </head><body><style>
            b{}
            </style><script>
            var a;
            </script>本文</body></html>
            """
        #expect(DocumentStatistics(html: html).characters == 2)
    }

    @Test("両面なら表裏で 2 ページずつの枚数になる")
    func duplexSheets() {
        #expect(DocumentStatistics.duplexSheets(pageCount: 0) == 0)
        #expect(DocumentStatistics.duplexSheets(pageCount: 1) == 1)
        #expect(DocumentStatistics.duplexSheets(pageCount: 6) == 3)
        #expect(DocumentStatistics.duplexSheets(pageCount: 7) == 4)
    }
}
