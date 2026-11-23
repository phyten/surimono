import Testing

@testable import SurimonoCore

@Suite("文書の構造", .timeLimit(.minutes(1)))
struct DocumentOutlineTests {
    @Test("コードの行番号で位置がずれても目次を探し直す")
    func printedCodeNumber() {
        let html = "<h1>Title</h1><pre>let sheets = 4</pre><nav class=\"toc\">Contents<a>A</a><a>B</a></nav>"
        let pages = ["Title\n1\nlet sheets = 4\nContents\nA\nB", "A\ntext", "B\ntext"]
        #expect(locations(["A", "B"], pages, html) == [1, 2])
    }

    @Test("番号付き目次の数字は各項目の中の数字と区別する")
    func numberedContentsLabels() {
        let html = "<nav class=\"toc\"><a>A2</a><a>B1</a></nav>"
        #expect(locations(["A2", "B1"], ["1. A2\n2. B1", "A2\ntext", "B1\ntext"], html) == [1, 2])
    }

    @Test("目次標題の下に同じ文字があっても別の語を項目にしない")
    func contentsAnagram() {
        let pages = ["Contents\nAC\nBD", "Contents\nAB\nCD", "AB\ntext", "CD\ntext"]
        #expect(locations(["AB", "CD"], pages) == [2, 3])
    }

    @Test("位置がなく同じ並びが二度続くときは目次ページを確定しない")
    func ambiguousContents() {
        #expect(locations(["A", "B"], ["A\nB", "A\nB"]) == [nil, nil])
    }

    @Test("先の目次の照合に失敗しても後ろの無題の目次は本文の境界で探し直す")
    func laterLocalContents() {
        let html = "<nav class=\"toc\"><a>X</a></nav><p>Before</p><nav class=\"toc\"><a>A</a><a>B</a></nav><p>After</p>"
        #expect(locations(["A", "B"], ["unprinted\nBefore\nB\nA\nAfter", "A\ntext", "B\ntext"], html) == [1, 2])
    }

    @Test("多数の同名標題を読み飛ばして長い目次を一度だけ除く")
    func manyContentsCaptions() {
        let entries = (1...1500).map { "A\($0)" }
        let pages = [
            String(repeating: "Contents\nx\n", count: 1500) + "Contents\n" + entries.joined(separator: "\n"), "A1",
        ]
        #expect(
            DocumentOutline.pages(
                of: [DocumentHeading(level: 1, text: "A1")], inPageTexts: pages, contentsEntries: entries) == [1])
    }

    @Test("題なしの目次は直後の段落だけが一致しても位置を回復できる")
    func followingBlockLocatesTable() {
        let html = "<p>Missing</p><nav class=\"toc\"><a>A</a><a>B</a></nav><p>Ch<span>apt</span>er introduction</p>"
        #expect(
            locations(["A", "B"], ["Generated\nB\nA\nChapter introduction", "A\ntext", "B\ntext"], html) == [1, 2])
    }

    @Test("同じ標題の後に二つの候補があれば原文の項目順を優先する")
    func prefersOrderedContents() {
        let pages = ["Contents\nB\nA", "B", "Contents\nA\nB", "A\ntext", "B\ntext"]
        #expect(locations(["A", "B"], pages) == [0, 1])
    }

    @Test("同じ順の本文と題なしの目次も DOM の境界があれば判別できる")
    func titlelessContentsAfterBody() {
        let html = "<h1>A</h1><h1>B</h1><nav class=\"toc\"><a>A</a><a>B</a></nav>"
        #expect(locations(["A", "B"], ["A\nB", "A\nB"], html) == [0, 0])
    }

    @Test("先の目次の一部が紙面にないときも同名の後続見出しに復帰する")
    func recoveryWithSharedLabels() {
        let html =
            "<nav class=\"toc\"><a>A</a><a>Missing</a></nav><p>Before</p>"
            + "<nav class=\"toc\"><a>A</a><a>B</a></nav><p>After</p>"
        #expect(locations(["A", "B"], ["A\nBefore\nB\nA\nAfter", "A\ntext", "B\ntext"], html) == [1, 2])
    }

    @Test("本文と目次の行をつないで折り返し見出しを作らない")
    func wrappedHeadingStopsAtContents() {
        let html = "<p>Book</p><nav class=\"toc\"><a>Title</a></nav>"
        #expect(locations(["BookTitle"], ["Book\nTitle", "BookTitle\ntext"], html) == [1])
    }

    private func locations(_ entries: [String], _ pages: [String], _ html: String = "") -> [Int?] {
        DocumentOutline.pages(
            of: entries.map { DocumentHeading(level: 1, text: $0) }, inPageTexts: pages,
            contentsEntries: entries, sourceContents: DocumentOutline.sourceContents(inHTML: html))
    }

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

    @Test("本文をはさんだ二つの目次の行は、どちらも見出しに取らない")
    func skipsSeveralSourceContents() {
        let headings = [
            DocumentHeading(level: 1, text: "A"), DocumentHeading(level: 2, text: "A1"),
            DocumentHeading(level: 1, text: "B"),
        ]
        // The table in front, the first heading with its own table, then the other headings.
        let pages = ["目次\nA\nA1\nB", "A\nA1", "A1\n本文", "B\n本文"]
        let html =
            "<nav class=\"toc\">目次<a>A</a><a>A1</a><a>B</a></nav><h1>A</h1>"
            + "<nav class=\"toc\"><a>A1</a></nav><h2>A1</h2><p>本文</p><h1>B</h1>"
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [
                    1, 2, 3,
                ])
        // Without the position, either of the two consecutive A1 lines could be the local table.
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["A", "A1", "B", "", "A1"]) == [
                1, nil, 3,
            ])
    }

    @Test("入れ子の目次の行が項目と違う順に読めても、見出しに取らない")
    func skipsSourceContentsReadOutOfOrder() {
        let headings = [
            DocumentHeading(level: 1, text: "A"), DocumentHeading(level: 2, text: "A1"),
            DocumentHeading(level: 1, text: "B"),
        ]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: ["目次\nA\nB\nA1", "A\n本文", "A1\n本文", "B\n本文"],
                contentsEntries: ["A", "A1", "B"]) == [1, 2, 3])
    }

    @Test("原文の目次が二つあるとき、その項目は空の項目で区切って返す")
    func separatesSourceContents() {
        let html = OrgConverter.convert("#+OPTIONS: toc:t\n* A\n#+TOC: headlines local\n** A1\n* B").body
        #expect(DocumentOutline.sourceContentsEntries(inHTML: html) == ["A", "A1", "B", "", "A1"])
    }

    @Test("末尾の目次と同じ語が別の順で並ぶ本文を見出し照合から除かない")
    func bodyRepeatsContentsOutOfOrder() {
        let headings = ["A", "B", "C"].map { DocumentHeading(level: 1, text: $0) }
        let pages = ["A\nC\nB", "C\n本文", "目次\nA\nB\nC"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["A", "B", "C"]) == [0, 0, 1])
        let html = OrgConverter.convert("#+LANGUAGE: ja\n* A\nC\n* B\n* C\n本文\n#+TOC: headlines").body
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [
                    0, 0, 1,
                ])
    }

    @Test("末尾の目次と同じ順で本物の見出しが続いても本文のページを残す")
    func orderedBodyBeforeNamedContents() {
        let html = OrgConverter.convert("#+LANGUAGE: ja\n* A\n* B\n* C\n#+TOC: headlines").body
        let headings = DocumentOutline.headings(inHTML: html)
        let pages = ["A\nB\nC", "目次\nA\nB\nC"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["A", "B", "C"]) == [0, 0, 0])
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [
                    0, 0, 0,
                ])
    }

    @Test("目次の DOM 位置で本文と題なしの目次を分け、目次の先頭項目が移動しても照合する")
    func localContentsRange() {
        let html = OrgConverter.convert("* B\n* C\n* Parent\n導入\n#+TOC: headlines local\n** B\n** C").body
        let pages = ["B\nC", "Parent\n導入\nC\nB", "B\n本文", "C"]
        #expect(
            DocumentOutline.pages(
                of: DocumentOutline.headings(inHTML: html), inPageTexts: pages,
                sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [0, 0, 1, 2, 3])
    }

    @Test("目次の先頭に移動した項目が折り返しても目次の範囲で照合する")
    func reorderedWrappedContents() {
        let html = OrgConverter.convert("#+OPTIONS: toc:t\n* A\n** LongHeading").body
        let pages = ["Table of Contents\nLong\nHeading\nA", "A", "LongHeading"]
        #expect(
            DocumentOutline.pages(
                of: DocumentOutline.headings(inHTML: html), inPageTexts: pages,
                sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [1, 2])
    }

    @Test("先頭とローカルの目次は DOM の位置にある行だけを読み飛ばす")
    func positionedContents() {
        let html = OrgConverter.convert("#+OPTIONS: toc:t\n* A\n#+TOC: headlines local\n** A1\n* B").body
        let pages = ["Table of Contents\nB\nA\nA1", "A\nA1", "A1\n本文", "B\n本文"]
        #expect(
            DocumentOutline.pages(
                of: DocumentOutline.headings(inHTML: html), inPageTexts: pages,
                sourceContents: DocumentOutline.sourceContents(inHTML: html)) == [1, 2, 3])
    }

    @Test("本文の後の目次でも本物の見出しを消さない")
    func keepsHeadingsBeforeSourceContents() {
        let headings = [DocumentHeading(level: 1, text: "第一章"), DocumentHeading(level: 1, text: "第二章")]
        let pages = ["第一章\n本文", "第二章\n本文", "第一章\n第二章"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["第一章", "第二章"]) == [0, 1])
    }

    @Test("先頭の項目が折り返した原文の目次も見出しに取らない")
    func skipsSourceContentsWithWrappedFirstEntry() {
        let headings = [DocumentHeading(level: 1, text: "導入方法について"), DocumentHeading(level: 1, text: "第二章")]
        let pages = ["導入方法\nについて\n第二章", "導入方法について\n本文", "第二章\n本文"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["導入方法について", "第二章"])
                == [1, 2])
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
    @Test("単独の表題を除き節ではなく章を選ぶ")
    func currentChapterIgnoresSections() {
        let entries: [OutlineEntry] = [
            .init(level: 1, title: "題", pageIndex: 0), .init(level: 2, title: "甲", pageIndex: 1),
            .init(level: 3, title: "節", pageIndex: 2), .init(level: 2, title: "乙", pageIndex: 4),
        ]
        #expect(DocumentOutline.currentChapter(in: entries, page: 0) == nil)
        #expect(DocumentOutline.currentChapter(in: entries, page: 3) == 1)
        #expect(DocumentOutline.currentChapter(in: entries, page: 4) == 3)
    }

    @Test("ページ不明の章を飛ばし同じページでは最後の章を選ぶ")
    func currentChapterSkipsUnknown() {
        let entries: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 2), .init(level: 1, title: "乙", pageIndex: 2),
            .init(level: 1, title: "不明", pageIndex: nil),
        ]
        #expect(DocumentOutline.currentChapter(in: entries, page: 1) == nil)
        #expect(DocumentOutline.currentChapter(in: entries, page: 2) == 1)
        #expect(DocumentOutline.currentChapter(in: entries, page: 10) == 1)
    }

    @Test("空の目次には今の章がない")
    func currentChapterEmpty() {
        #expect(DocumentOutline.currentChapter(in: [], page: 0) == nil)
    }

    @Test("今の章の題名はヘッダーの章と全ページで一致する")
    func currentChapterMatchesFurniture() {
        let entries: [OutlineEntry] = [
            .init(level: 1, title: "題", pageIndex: 0), .init(level: 2, title: "甲", pageIndex: 1),
            .init(level: 3, title: "節", pageIndex: 2), .init(level: 2, title: "乙", pageIndex: 3),
            .init(level: 2, title: "丙", pageIndex: 3), .init(level: 2, title: "不明", pageIndex: nil),
        ]
        let titles = PageChapters.titles(
            headings: entries.map { DocumentHeading(level: $0.level, text: $0.title) }, pages: entries.map(\.pageIndex),
            pageCount: 5)
        #expect(titles == ["", "甲", "甲", "丙", "丙"])
        for page in 0..<5 {
            #expect(
                DocumentOutline.currentChapter(in: entries, page: page).map { entries[$0].title } ?? "" == titles[page])
        }
    }

}
