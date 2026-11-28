import RobustnessSupport
import Testing

@testable import SurimonoCore

/// A formula as a heading's printed text marks it, with its source.
private func formula(_ tex: String) -> String {
    "\(DocumentHeading.formulaStart)\(tex)\(DocumentHeading.formulaEnd)"
}

@Suite("文書の構造", .timeLimit(.minutes(1)))
struct DocumentOutlineTests {
    @Test("コードに行番号が加わっても原稿順の目次を読み飛ばす")
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

    @Test("本文の後の番号付き目次は手で番号を付けた見出しと区別する")
    func handNumberedHeadingBeforeContents() {
        let titles = ["Overview", "1. Overview", "Conclusion"]
        let pages = ["Overview\n1. Overview\n2. 1. Overview\n3. Conclusion", "1. Overview\nbody", "Conclusion\nbody"]
        let headings = titles.map { DocumentHeading(level: 1, text: $0) }
        #expect(MasterOutlineReference.pages(of: headings, inPageTexts: pages, contentsEntries: titles) == [0, 1, 2])
        #expect(locations(titles, pages) == [0, 1, 2])
    }

    @Test("数字だけが残る行から始まる折り返し目次も master と同じ範囲を除く")
    func numberedEmptyFirstLine() {
        let titles = ["11119", "1111Title", "B"]
        let entries = ["1111Title", "B"]
        let pages = ["11119. !\n1111Title\nB", "11119\nbody", "1111Title\nbody", "B\nbody"]
        let headings = titles.map { DocumentHeading(level: 1, text: $0) }
        #expect(MasterOutlineReference.pages(of: headings, inPageTexts: pages, contentsEntries: entries) == [1, 2, 3])
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries) == [1, 2, 3])
    }

    @Test("番号付き・重複・折り返しを含む目次六千例の照合が master と一致する")
    func comparesOrderedRunsWithMaster() {
        var random = SeededGenerator(seed: 0x266_06)
        let labels = ["A", "1. A", "B", "2. B", "Overview", "1. Overview", "Overview Field", "結論"]
        func pick(_ count: Int) -> Int { Int(random.next() % UInt64(count)) }
        func printLabel(_ label: String) -> String {
            let number = ["", "1. ", "2. ", "１．"][pick(4)]
            let text = pick(2) == 0 ? label.replacingOccurrences(of: "Overview Field", with: "Overview\nField") : label
            return number + text
        }
        for example in 0..<6_000 {
            let titles = (0..<(1 + pick(8))).map { _ in labels[pick(labels.count)] }
            var blocks = titles.map { printLabel($0) + "\n本文" }
            var entries: [String] = []
            var afterTable = 0
            let tableCount = example % 3 == 2 ? 2 + pick(2) : 1
            for _ in 0..<tableCount {
                let labelsInTable = pick(3) == 0 ? (0..<(1 + pick(6))).map { _ in labels[pick(labels.count)] } : titles
                if !entries.isEmpty { entries.append("") }
                entries += labelsInTable
                // A prefix can stand immediately before a whole table, or the table can be missing on paper.
                var printed = labelsInTable.prefix(pick(labelsInTable.count + 1)).map { printLabel($0) }
                var table = labelsInTable.map { printLabel($0) }
                if pick(4) == 0 { table[pick(table.count)] = "別の行" }
                printed += table
                let start = afterTable + pick(blocks.count - afterTable + 1)
                blocks.insert(contentsOf: printed, at: start)
                afterTable = start + printed.count
            }
            var pages = [""]
            for block in blocks {
                if !pages[pages.count - 1].isEmpty && pick(3) == 0 { pages.append("") }
                pages[pages.count - 1] += block + "\n"
            }
            let headings = titles.map { DocumentHeading(level: 1, text: $0) }
            let expected = MasterOutlineReference.pages(of: headings, inPageTexts: pages, contentsEntries: entries)
            let actual = DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries)
            if expected != actual {
                Issue.record("例 \(example) 見出し \(titles) 目次 \(entries) 紙面 \(pages) 期待 \(expected) 実際 \(actual)")
                return
            }
        }
    }

    @Test("目次標題の下に同じ文字があっても別の語を項目にしない")
    func contentsAnagram() {
        let pages = ["Contents\nAC\nBD", "Contents\nAB\nCD", "AB\ntext", "CD\ntext"]
        #expect(locations(["AB", "CD"], pages) == [2, 3])
    }

    @Test("本文と目次の行をつないで折り返し見出しを作らない")
    func wrappedHeadingStopsAtContents() {
        let html = "<p>Book</p><nav class=\"toc\"><a>Title</a></nav>"
        #expect(locations(["BookTitle"], ["Book\nTitle", "BookTitle\ntext"], html) == [1])
    }

    @Test("同じ標題の目次が二千個続いても本文のページを短時間で見つける")
    func repeatedContentsTables() {
        let count = 2_000
        let table = "<nav class=\"toc\">Contents<a>A</a></nav>"
        let html = "<pre>x\ny</pre>" + String(repeating: table, count: count) + "<h1>A</h1><p>body</p>"
        let pages = ["1\nx\n2\ny\n" + String(repeating: "Contents\nA\n", count: count), "A\nbody"]
        let elapsed = ContinuousClock().measure {
            let entries = DocumentOutline.sourceContentsEntries(inHTML: html)
            #expect(
                DocumentOutline.pages(
                    of: [DocumentHeading(level: 1, text: "A")], inPageTexts: pages, contentsEntries: entries) == [1])
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("目次の先頭と途中が同じ項目でも、重なった並びの途中から全項目が続けば除く")
    func overlappingContentsPrefix() {
        #expect(locations(["A", "A", "B"], ["A", "A\nA\nB", "A\n本文", "B"]) == [0, 2, 3])
    }

    @Test("長い目次の開始候補が重なっても、番号を含む項目の別表記を残して照合する")
    func manyOverlappingStarts() {
        let count = 3_200
        let headings = ["A", "B"].map { DocumentHeading(level: 1, text: $0) }
        let entries = (0..<count).map { $0.isMultiple(of: 2) ? "A" : "1. A" } + ["B"]
        let lines = Array(repeating: "1. A", count: count).joined(separator: "\n")
        let elapsed = ContinuousClock().measure {
            let pages = DocumentOutline.pages(
                of: headings, inPageTexts: [lines, lines + "\nB", "B"], contentsEntries: entries)
            #expect(pages == [0, 2])
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("目次の途中で短い行に折り返した項目も元の順で読み飛ばす")
    func shortWrappedContentsEntry() {
        #expect(locations(["A", "Short"], ["A\nSh\nort", "A\n本文", "Short"]) == [1, 2])
    }

    @Test("目次の前後の複数行コードに行番号が加わっても一意な項目順から見出しを探せる")
    func contentsBetweenNumberedCodeBlocks() {
        let html =
            "<pre>let x = 1\nlet z = 2</pre><nav class=\"toc\"><a>Alpha</a><a>Beta</a></nav>"
            + "<pre>let y = 2\nlet q = 3</pre><h1>Alpha</h1><p>body</p><h1>Beta</h1><p>body</p>"
        let pages = [
            "1\nlet x = 1\n2\nlet z = 2\nAlpha\nBeta\n1\nlet y = 2\n2\nlet q = 3", "Alpha\nbody", "Beta\nbody",
        ]
        #expect(locations(["Alpha", "Beta"], pages, html) == [1, 2])
    }

    @Test("目次だけにある共通接頭辞の見出し一万六千件を短時間で照合する")
    func sharedPrefixInContentsOnly() {
        let labels = (0..<16_000).map { "Chapter\($0)" }
        let headings = labels.map { DocumentHeading(level: 1, text: $0) }
        let html = "<nav class=\"toc\">Contents" + labels.map { "<a>\($0)</a>" }.joined() + "</nav>"
        let pages = ["Contents\n" + labels.joined(separator: "\n")]
        let elapsed = ContinuousClock().measure {
            let matches = DocumentOutline.pages(
                of: headings, inPageTexts: pages,
                contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
            #expect(matches.count == labels.count && matches.allSatisfy { $0 == nil })
        }
        #expect(elapsed < .seconds(2))
    }

    @Test("行番号のあるコードと目次が百組続く三十四ページでも全見出しのページが分かる")
    func hundredPrintedTables() {
        let labels = (0..<100).map { "Chapter\($0)" }
        var html = ""
        var pages = Array(repeating: "", count: 34)
        for (i, label) in labels.enumerated() {
            html +=
                "<pre>let x = \(i)\nlet y = \(i)</pre><nav class=\"toc\">Contents<a>\(label)</a></nav>"
                + "<p>Body\(i)</p><h1>\(label)</h1><p>text</p>"
            pages[i / 3] += "1\nlet x = \(i)\n2\nlet y = \(i)\nContents\n\(label)\nBody\(i)\n"
            pages[(i + 1) / 3] += "\(label)\ntext\n"
        }
        #expect(locations(labels, pages, html) == labels.indices.map { ($0 + 1) / 3 })
    }

    private func locations(_ entries: [String], _ pages: [String], _ html: String = "") -> [Int?] {
        DocumentOutline.pages(
            of: entries.map { DocumentHeading(level: 1, text: $0) }, inPageTexts: pages,
            contentsEntries: html.isEmpty ? entries : DocumentOutline.sourceContentsEntries(inHTML: html))
    }

    @Test("HTML から見出しの深さ・文字・ID を読む")
    func readsHeadings() {
        let html = #"<h1 id="a">はじめに</h1><p>本文</p><h2>開館の<em>手順</em></h2>"#
        #expect(
            DocumentOutline.headings(inHTML: html) == [
                DocumentHeading(level: 1, text: "はじめに", id: "a"), DocumentHeading(level: 2, text: "開館の手順"),
            ])
    }

    @Test("節の番号の後に空白を入れ、入れ子の番号も、もとからある空白も二重にしない")
    func spacesSectionNumbers() {
        let html =
            #"<h2><span class="secnum">1</span>はじめに</h2>"#
            + #"<h2><span class="secnum">第<span class="latex-xkanjiskip"> </span>2<span> </span>章</span>決まり</h2>"#
            + #"<h3><span class="secnum">2.1</span> 冊数</h3><h3><span class="secnum">2.2</span>&nbsp;手順</h3>"#
            + #"<h3><span class="secnum">2.3</span></h3><h3><span class="other">3</span>題</h3>"#
        #expect(
            DocumentOutline.headings(inHTML: html).map(\.text) == [
                "1 はじめに", "第 2 章 決まり", "2.1 冊数", "2.2\u{A0}手順", "2.3", "3題",
            ])
    }

    @Test("Org のタグと作業の語は見出しの題に入れず、本文の文字数には数える")
    func leavesOutOrgTags() {
        let tags = #"<span class="org-tags"><span class="org-tag">list</span> <span class="org-tag">art</span></span>"#
        let html = "<h3><span class=\"org-todo\">NEXT</span> 持ち物 \(tags)</h3><p>\(tags)</p>"
        #expect(DocumentOutline.headings(inHTML: html).map(\.text) == ["持ち物"])
        #expect(DocumentStatistics(html: html).characters == "NEXT持ち物listartlistart".count)
    }

    @Test("閉じていない Org のタグや閉じタグのない要素のタグは、その見出しの中だけで外し、次の見出しを残す")
    func unclosedOrgTagsStayInHeading() {
        #expect(
            DocumentOutline.headings(inHTML: #"<h2>A<span class="org-tags">tag</h2><h2>B</h2>"#).map(\.text)
                == ["A", "B"])
        #expect(
            DocumentOutline.headings(inHTML: #"<h2>A<br class="org-tags">B</h2><h2>C</h2>"#).map(\.text)
                == ["AB", "C"])
    }

    @Test("タブや改行で区切ったクラスの Org のタグも外す")
    func orgTagsAmongClassesSeparatedByTabs() {
        let html = "<h2>A<span class=\"x\torg-tags\">tag</span></h2><h2>B<span class=\"x\norg-tags\">tag</span></h2>"
        #expect(DocumentOutline.headings(inHTML: html).map(\.text) == ["A", "B"])
    }

    @Test("節の番号の後の空白が長い文字参照で書かれていても二重にせず、閉じていない番号は次の見出しに持ち越さない")
    func sectionNumberEdges() {
        let html =
            #"<h3><span class="secnum">1</span>&#000032;題</h3>"#
            + #"<h2><span class="secnum">2</h2><h2>次</h2>"#
        #expect(DocumentOutline.headings(inHTML: html).map(\.text) == ["1 題", "2", "次"])
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
                of: headings, inPageTexts: pages, contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
                == [1, 2, 3])
    }

    @Test("入れ子の目次が原稿と違う順で読まれたときは、目次の行も見出しに一致する")
    func reorderedContentsRemainSearchable() {
        let headings = [
            DocumentHeading(level: 1, text: "A"), DocumentHeading(level: 2, text: "A1"),
            DocumentHeading(level: 1, text: "B"),
        ]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: ["目次\nA\nB\nA1", "A\n本文", "A1\n本文", "B\n本文"],
                contentsEntries: ["A", "A1", "B"]) == [0, 0, 3])
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
                of: headings, inPageTexts: pages, contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
                == [
                    0, 0, 1,
                ])
    }

    @Test("末尾の目次と同じ順で本物の見出しが先に続けば、先の並びを目次として除く")
    func orderedBodyBeforeNamedContents() {
        let html = OrgConverter.convert("#+LANGUAGE: ja\n* A\n* B\n* C\n#+TOC: headlines").body
        let headings = DocumentOutline.headings(inHTML: html)
        let pages = ["A\nB\nC", "目次\nA\nB\nC"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
                == [
                    1, 1, 1,
                ])
    }

    @Test("本文の後の目次でも本物の見出しを消さない")
    func keepsHeadingsBeforeSourceContents() {
        let headings = [DocumentHeading(level: 1, text: "第一章"), DocumentHeading(level: 1, text: "第二章")]
        let pages = ["第一章\n本文", "第二章\n本文", "第一章\n第二章"]
        #expect(
            DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: ["第一章", "第二章"]) == [0, 1])
    }

    @Test("タグ付きの Org の目次を照合から外し、章が本文のページに当たる")
    func orgContentsWithTags() {
        let html = OrgConverter.convert("#+OPTIONS: toc:t num:t tags:t\n* 前提 :scope:\n本文\n* 関係 :evidence:\n本文").body
        let headings = DocumentOutline.headings(inHTML: html)
        // The tags float to the right of each line; the page's text gives them after the whole table.
        let pages = ["目次\n1. 前提\n2. 関係\nscope\nevidence", "1. 前提\nscope\n本文", "2. 関係\nevidence\n本文"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, contentsEntries: DocumentOutline.sourceContentsEntries(inHTML: html))
                == [1, 2])
    }

    @Test("番号だけの行の次に題が組まれた見出しにもページが付く")
    func numberOnItsOwnLine() {
        let headings = ["1 盆の識別", "1.1 札の扱い", "第 2 章 返却と予約"].map { DocumentHeading(level: 2, text: $0) }
        let pages = ["前書きの文。\n1\n盆の識別\n本文の文。\n1.1\n札の扱い\n本文の文。", "2\n第2 章\n返却と予約\n本文の文。"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [0, 0, 1])
    }

    @Test("番号だけの行の後でも、題が文の途中の行ならその見出しとはしない")
    func numberLineBeforeSentence() {
        let headings = [DocumentHeading(level: 2, text: "1 盆の識別")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["1\n盆の識別の手順を次に述べる。"]) == [nil])
    }

    @Test("数式を含む見出しは、式の所を飛ばして前後の文字でページを探す")
    func headingWithFormula() {
        let headings = [
            DocumentHeading(level: 2, text: "収録条件 n\\neq0", printed: "収録条件 " + formula("n\\neq0")),
            DocumentHeading(level: 2, text: "α+β と index の対応", printed: formula("\\alpha+\\beta") + " と index の対応"),
        ]
        let pages = ["表題\n1. 収録条件 n≠0\n本文の文。", "4.1. α + β と index の対応\n本文の文。"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [0, 1])
    }

    @Test("数式を含む見出しの前の言葉で始まる文の行は、その見出しとはしない")
    func formulaHeadingNotInSentence() {
        let headings = [DocumentHeading(level: 2, text: "収録条件 n\\neq0", printed: "収録条件 " + formula("n\\neq0"))]
        let pages = ["収録条件を満たす標本は、棚の上段に置いて記録を付ける決まりとし、例外は設けないことにした。", "収録条件 n≠0\n本文の文。"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [1])
    }

    @Test("数式を含む原文の目次の行も見出しに取らない")
    func contentsWithFormula() {
        let headings = [
            DocumentHeading(level: 2, text: "収録条件 n\\neq0", printed: "収録条件 " + formula("n\\neq0")),
            DocumentHeading(level: 2, text: "保存"),
        ]
        let pages = ["目次\n1. 収録条件 n≠0\n2. 保存", "1. 収録条件 n≠0\n本文の文。\n2. 保存\n本文の文。"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, contentsEntries: ["1. 収録条件 " + formula("n\\neq0"), "2. 保存"]) == [
                    1, 1,
                ])
    }

    @Test("数式の前の言葉で始まる短い文の行は、数式を含む見出しとはしない")
    func formulaHeadingNotInShortSentence() {
        let headings = [DocumentHeading(level: 2, text: "収録条件 n\\neq0", printed: "収録条件 " + formula("n\\neq0"))]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["収録条件を確認する。", "収録条件 n≠0\n本文"]) == [1])
    }

    @Test("番号と数式だけの見出しは、別の見出しの行に当てない")
    func numberAndFormulaOnly() {
        let headings = [DocumentHeading(level: 3, text: "1.1 x", printed: "1.1 " + formula("x"))]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["1.1 違う見出し\n本文の文。"]) == [nil])
    }

    @Test("数式の所に式にない言葉が入った行は、その見出しとはしない")
    func formulaGapHoldsOnlyFormulaLetters() {
        let headings = [DocumentHeading(level: 2, text: "Section x", printed: "Section " + formula("x"))]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["Section intro\nBody", "Section x\nBody"]) == [1])
    }

    @Test("数式が別の行に出た原文の目次も、見出しの照合から外す")
    func contentsWithFormulaOnNextLine() {
        let headings = [
            DocumentHeading(level: 2, text: "Section x", printed: "Section " + formula("x")),
            DocumentHeading(level: 2, text: "Next"),
        ]
        let pages = ["Contents\nSection\nx\nNext", "Section x\nBody\nNext\nBody"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, contentsEntries: ["Section " + formula("x"), "Next"]) == [1, 1])
    }

    @Test("数式だけの項目がある原文の目次も、見出しの照合から外す")
    func contentsWithFormulaOnlyEntry() {
        let headings = [DocumentHeading(level: 2, text: "Intro"), DocumentHeading(level: 2, text: "Next")]
        let pages = ["Contents\nIntro\nE = mc2\nNext", "Intro\nBody\nE = mc2\nNext\nBody"]
        #expect(
            DocumentOutline.pages(
                of: headings, inPageTexts: pages, contentsEntries: ["Intro", formula("E=mc^2"), "Next"]) == [1, 1])
    }

    @Test("数式が別の行に出た先の原文の目次を見つければ、後の目次も見出しの照合から外す")
    func laterContentsAfterFormulaContents() {
        let headings = [
            DocumentHeading(level: 2, text: "Section x", printed: "Section " + formula("x")),
            DocumentHeading(level: 2, text: "Next"), DocumentHeading(level: 2, text: "Alpha"),
            DocumentHeading(level: 2, text: "Beta"),
        ]
        let pages = [
            "Contents\nSection\nx\nNext\nMore contents\nAlpha\nBeta",
            "Section x\nBody\nNext\nBody\nAlpha\nBody\nBeta\nBody",
        ]
        let entries = ["Section " + formula("x"), "Next", "", "Alpha", "Beta"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries) == [1, 1, 1, 1])
    }

    @Test("同じ項目が二千続き数式を含む目次の照合も、三百ページで短時間に終わる")
    func repeatedFormulaContentsIsBounded() {
        let title = "Repeated " + formula("x")
        let entries = Array(repeating: title, count: 1999) + ["Missing " + formula("y")]
        let headings = entries.map { DocumentHeading(level: 2, text: "Repeated x", printed: $0) }
        let pages = Array(repeating: Array(repeating: "Repeated x", count: 50).joined(separator: "\n"), count: 300)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries)
        }
        #expect(elapsed < .seconds(3), "\(elapsed)")
    }

    @Test("見つからない見出しが多くても、後ろの番号だけの行の見出しを探す")
    func lineByLineSearchSharesItsBudget() {
        let lines = (0..<5000).map { "xline\($0)" } + ["1", "Last heading", "Body."]
        let headings =
            (0..<100).map { DocumentHeading(level: 2, text: "xmissing\($0)") }
            + [DocumentHeading(level: 2, text: "1 Last heading")]
        let pages = DocumentOutline.pages(of: headings, inPageTexts: [lines.joined(separator: "\n")])
        #expect(pages.last == 0)
    }

    @Test("大文字に組まれ、番号だけの行に続く見出しや数式を含む見出しにもページが付く")
    func capitalsWithJoinedLinesAndFormulas() {
        let numbered = [DocumentHeading(level: 1, text: "1 Introduction")]
        #expect(DocumentOutline.pages(of: numbered, inPageTexts: ["Title\n1\nINTRODUCTION\nWe study paper."]) == [0])
        let energy = [DocumentHeading(level: 1, text: "Energy E=mc^2", printed: "Energy " + formula("E=mc^2"))]
        #expect(DocumentOutline.pages(of: energy, inPageTexts: ["ENERGY E=mc2\nBody"]) == [0])
    }

    @Test("数式で始まる章がページの頭にあれば、前の章はその前のページで終わる")
    func chapterOpeningWithFormula() {
        let headings = [
            DocumentHeading(level: 1, text: "Intro"),
            DocumentHeading(level: 1, text: "\\alpha の章", printed: formula("\\alpha") + " の章"),
        ]
        let texts = ["Intro\nBody", "Body", "α の章\nBody"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 2], inPageTexts: texts) == [1])
    }

    @Test("数式を含む章の前の言葉で始まる文がページの頭にあっても、章はそのページを開かない")
    func chapterNotOpenedBySentence() {
        let headings = [
            DocumentHeading(level: 1, text: "Intro"),
            DocumentHeading(level: 1, text: "収録条件 n\\neq0", printed: "収録条件 " + formula("n\\neq0")),
        ]
        let texts = ["Intro\nBody", "Body", "収録条件を確認する。\n収録条件 n≠0\nBody"]
        #expect(DocumentOutline.chapterEnds(of: headings, pages: [0, 2], inPageTexts: texts) == [2])
    }

    @Test("同じ文字を取り合う数式が多く並ぶ見出しも、一度の照合が短時間で終わる")
    func manyFormulasMatchQuickly() {
        let printed = "Head " + Array(repeating: formula("x+x"), count: 24).joined(separator: " ") + " End"
        let headings = [DocumentHeading(level: 2, text: "Head x End", printed: printed)]
        let line = "Head " + String(repeating: "x", count: 36) + "y End"
        let elapsed = ContinuousClock().measure {
            #expect(DocumentOutline.pages(of: headings, inPageTexts: [line + "\nBody"]) == [nil])
        }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test("文字の残らない記号だけの式を含む見出しにもページが付く")
    func symbolOnlyFormula() {
        for (source, glyph) in [("\\infty", "∞"), ("\\times", "×"), ("\\sum", "∑")] {
            let headings = [DocumentHeading(level: 2, text: "Limit " + source, printed: "Limit " + formula(source))]
            #expect(DocumentOutline.pages(of: headings, inPageTexts: ["前書き", "Limit \(glyph)\nBody"]) == [1])
        }
    }

    @Test("記号だけの式を含む項目のある原文の目次も、見出しの照合から外す")
    func contentsWithSymbolOnlyFormula() {
        let headings = [
            DocumentHeading(level: 2, text: "Intro"),
            DocumentHeading(level: 2, text: "Limit \\infty", printed: "Limit " + formula("\\infty")),
            DocumentHeading(level: 2, text: "Next"),
        ]
        let pages = ["Contents\nIntro\nLimit ∞\nNext", "Intro\nBody", "Limit ∞\nBody", "Next\nBody"]
        let entries = ["Intro", "Limit " + formula("\\infty"), "Next"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries) == [1, 2, 3])
    }

    @Test("記号だけの式が項目の原文の目次も、見出しの照合から外す")
    func contentsWithSymbolOnlyEntry() {
        let headings = [DocumentHeading(level: 2, text: "Intro"), DocumentHeading(level: 2, text: "Next")]
        let pages = ["Contents\nIntro\n∞\nNext", "Intro\nBody", "Next\nBody"]
        let entries = ["Intro", formula("\\infty"), "Next"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages, contentsEntries: entries) == [1, 2])
    }

    @Test("書いたとおりの綴りで行をつないだ見出しを、大文字だけ違う行より先に採る")
    func writtenJoinedLinesBeforeFoldedIndex() {
        let headings = [DocumentHeading(level: 1, text: "1 Introduction"), DocumentHeading(level: 1, text: "Next")]
        let pages = ["1 INTRODUCTION\nBody", "1\nIntroduction\nBody", "Next\nBody"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [1, 2])
    }

    @Test("脚注の番号を付けて組まれた見出しは、題に番号を入れずにページが付く")
    func headingWithFootnoteNumber() {
        let heading = DocumentHeading(level: 2, text: "保存場所の変更", printed: "保存場所の変更1")
        let entries = DocumentOutline.entries(of: [heading], inPageTexts: ["前書き", "2. 保存場所の変更1\n本文の文。"])
        #expect(entries == [OutlineEntry(level: 2, title: "保存場所の変更", pageIndex: 1)])
    }

    @Test("大文字に組まれた見出しにページが付く")
    func capitalizedHeadings() {
        let headings = ["I. Introduction", "II. Related work", "A. Data sets"].map {
            DocumentHeading(level: 1, text: $0)
        }
        let pages = ["Title\nI. INTRODUCTION\nWe study paper.", "II. RELATED WORK\nEarlier work.\nA. DATA SETS\nRows."]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [0, 1, 1])
    }

    @Test("ß を含む見出しは、大文字で SS と組まれてもページが付く")
    func capitalizedSharpS() {
        let headings = [DocumentHeading(level: 1, text: "Die Straße")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["Vorwort\nDIE STRASSE\nText"]) == [0])
    }

    @Test("大文字と小文字だけが違う前の行より、書いたとおりの綴りの見出しを採る")
    func writtenCaseFirst() {
        let headings = [DocumentHeading(level: 1, text: "US")]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["Us\n前置きの本文", "US\nこの節の本文"]) == [1])
    }

    @Test("大文字に組まれた見出しは、前後の見つかった見出しの間でだけ探す")
    func capitalizedHeadingBetweenFoundOnes() {
        let headings = ["Alpha", "Notes", "Gamma"].map { DocumentHeading(level: 1, text: $0) }
        let pages = ["NOTES\n本文", "Alpha\n本文", "NOTES\n本文", "Gamma\n本文"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: pages) == [1, 2, 3])
        // A "NOTES" before Alpha or after Gamma is not taken for the heading between them, and Gamma keeps its page.
        let outside = ["NOTES\n本文", "Alpha\n本文", "Gamma\n本文", "NOTES\n本文"]
        #expect(DocumentOutline.pages(of: headings, inPageTexts: outside) == [1, nil, 2])
    }

    @Test("大文字と小文字をそろえても、ǰ と J、ΐ と Ι のような付け記号の違いは区別する")
    func foldingKeepsMarks() {
        #expect(DocumentOutline.pages(of: [DocumentHeading(level: 1, text: "ǰ")], inPageTexts: ["J\n本文"]) == [nil])
        #expect(DocumentOutline.pages(of: [DocumentHeading(level: 1, text: "ΐ")], inPageTexts: ["Ι\n本文"]) == [nil])
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

    @Test("先の見出しが折り返しの途中で外れても、次の二行の見出しを見つける")
    func overlappingWrappedTitles() {
        let headings = ["FirstPartTail", "PartRest", "End"].map { DocumentHeading(level: 1, text: $0) }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["First\nPart\nRest", "End"]) == [nil, 0, 1])
    }

    @Test("長い見出しが同じ折り返し行を取り合う場合は先に始まる並びを読む")
    func overlappingLongHeadings() {
        let headings = ["BetaGammaDelta", "AlphaBetaGammaDelta"].map { DocumentHeading(level: 1, text: $0) }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: ["Alpha\nBeta\nGamma\nDelta"]) == [nil, 0])
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
