import Foundation
import SurimonoCore
import Testing

struct PrintFinishTests {
    private func heading(_ level: Int, _ text: String) -> DocumentHeading { DocumentHeading(level: level, text: text) }

    @Test("既定の仕上げは CSS を足さない")
    func defaultsAddNothing() throws {
        #expect(PrintFinish().styleSheet.isEmpty)
        let decoded = try JSONDecoder().decode(PrintFinish.self, from: Data("{}".utf8))
        #expect(decoded == PrintFinish())
    }

    @Test("見出しの改ページは最初の見出しと見出しの直後を除く")
    func headingBreaks() {
        var finish = PrintFinish()
        finish.breaks.h1 = .page
        finish.breaks.h2 = .rightPage
        let css = finish.styleSheet
        #expect(css.contains(":is(h1, h2, h3, h4, h5, h6) ~ h1, :is(h1, h2, h3, h4, h5, h6) ~ h2 { break-before: page"))
        #expect(css.contains(":is(h1, h2, h3, h4, h5, h6) + h2"))
        #expect(css.contains(".page-break[data-syntax=\"newpage\"] + h1"))
    }

    @Test("原文の記法は設定で一つずつ切れ、--- は頼んだときだけ改ページになる")
    func syntaxSwitches() {
        var finish = PrintFinish()
        finish.breaks.ignoredSyntaxes = [.newpage]
        #expect(finish.styleSheet.contains(".page-break[data-syntax=\"newpage\"] { break-after: auto"))
        #expect(!finish.styleSheet.contains("hr {"))
        finish.breaks.breaksAtThematicBreaks = true
        #expect(finish.styleSheet.contains("hr {"))
    }

    @Test("目次を出さないとき、先頭に足して原文の分を残さないときは原文の目次を隠す")
    func hidesSourceContents() {
        var finish = PrintFinish()
        finish.toc.mode = .source
        #expect(!finish.styleSheet.contains("nav.toc"))
        finish.toc.mode = .hidden
        #expect(finish.styleSheet.contains("nav.toc { display: none"))
        finish.toc.mode = .front
        #expect(finish.styleSheet.contains("nav.toc { display: none"))
        finish.toc.keepsSourceTOC = true
        #expect(!finish.styleSheet.contains("nav.toc"))
    }

    @Test("未知の値があっても他の項目を残す")
    func tolerantDecoding() throws {
        let json =
            #"{"breaks":{"h1":"future","h2":"page","ignoredSyntaxes":["future","newpage"]},"toc":{"mode":"front"}}"#
        let finish = try JSONDecoder().decode(PrintFinish.self, from: Data(json.utf8))
        #expect(finish.breaks.h1 == .none)
        #expect(finish.breaks.h2 == .page)
        #expect(finish.breaks.ignoredSyntaxes == [.newpage])
        #expect(finish.toc.mode == .front)
    }

    @Test("仕上げは JSON で往復する")
    func roundTrip() throws {
        var finish = PrintFinish()
        finish.breaks.h3 = .rightPage
        finish.breaks.ignoredSyntaxes = [.kramdown, .comment]
        finish.breaks.customLine = "＝＝改ページ＝＝"
        finish.toc.look = .ruled
        #expect(try JSONDecoder().decode(PrintFinish.self, from: JSONEncoder().encode(finish)) == finish)
    }

    @Test("右ページから始める章は、偶数ページに当たるときだけ前に白紙を入れる")
    func blankBeforeLeftPage() {
        let plan = FinishedPagePlan(bodyPageCount: 5, contentsPageCount: 0, rightPageStarts: [0, 2, 3])
        // Pages: 1 is on the right; the chapter at body page 2 falls on page 3; the next would fall on page 4.
        #expect(plan.pages == [.body(0), .body(1), .body(2), .blank, .body(3), .body(4)])
        #expect(plan.bodyPageIndices == [0, 1, 2, 4, 5])
        #expect(plan.blankPages == [3])
        #expect(plan.contentsPageCount == 0)
    }

    @Test("目次のページ数も右ページの判定に数える")
    func contentsCountForRightPages() {
        let plan = FinishedPagePlan(bodyPageCount: 2, contentsPageCount: 1, rightPageStarts: [0])
        #expect(plan.pages == [.contents(0), .blank, .body(0), .body(1)])
        let two = FinishedPagePlan(bodyPageCount: 2, contentsPageCount: 2, rightPageStarts: [0])
        #expect(two.pages == [.contents(0), .contents(1), .body(0), .body(1)])
    }

    @Test("右ページの規則の見出しだけを右ページの開始に数える")
    func rightPageStarts() {
        var rules = PageBreakRules()
        rules.h1 = .rightPage
        rules.h2 = .page
        let headings = [heading(1, "一"), heading(2, "節"), heading(1, "二"), heading(1, "三")]
        let starts = FinishedPagePlan.rightPageStarts(
            headings: headings, pages: [0, 1, 3, nil], followsHeading: [false, false, false, false], rules: rules)
        #expect(starts == [0, 3])
    }

    @Test("見出しの直下の見出しと、ページの途中にある最初の見出しは右ページの開始にしない")
    func rightPageExceptions() {
        var rules = PageBreakRules()
        rules.h1 = .rightPage
        rules.h2 = .rightPage
        let starts = FinishedPagePlan.rightPageStarts(
            headings: [heading(1, "題"), heading(2, "節"), heading(2, "次")], pages: [1, 1, 2],
            followsHeading: [false, true, false], rules: rules)
        #expect(starts == [2])
    }

    @Test("目次の章は一番大きい見出しで、題名だけのときは次の大きさを章にする")
    func contentsEntries() {
        let book = [heading(1, "一"), heading(2, "節"), heading(3, "項"), heading(1, "二")]
        let chapters = PaperContents.entries(headings: book, pageNumbers: [1, 2, 3, 4], depth: .chapters)
        #expect(chapters.map(\.text) == ["一", "二"])
        #expect(chapters.map(\.page) == [1, 4])
        let sections = PaperContents.entries(headings: book, pageNumbers: [1, 2, 3, 4], depth: .sections)
        #expect(sections.map(\.text) == ["一", "節", "二"])
        #expect(sections.map(\.depth) == [1, 2, 1])
        let titled = [heading(1, "題名"), heading(2, "一"), heading(2, "二")]
        #expect(
            PaperContents.entries(headings: titled, pageNumbers: [1, 1, 2], depth: .chapters).map(\.text) == ["一", "二"])
    }

    @Test("目次の文字はエスケープし、見た目ごとに線を変える")
    func contentsFragment() {
        let entries = [PaperContents.Entry(depth: 1, text: "a<b", page: 3)]
        let dotted = PaperContents.fragment(entries: entries, look: .dotted, title: "目次").body
        #expect(dotted.contains("a&lt;b"))
        #expect(dotted.contains("<span class=\"paper-toc-page\">3</span>"))
        #expect(dotted.contains("dotted"))
        #expect(!PaperContents.fragment(entries: entries, look: .plain, title: "目次").body.contains("border-bottom"))
        #expect(PaperContents.fragment(entries: entries, look: .ruled, title: "目次").body.contains("solid"))
    }

    @Test("原文の目次の行は見出しの位置に数えない")
    func sourceContentsLines() {
        let html = """
            <h1 id="a">序</h1><nav class="toc"><ul><li><a href="#a">序</a></li><li><a href="#b">本編</a></li></ul></nav>
            <h1 id="b">本編</h1>
            """
        let entries = DocumentOutline.sourceContentsEntries(inHTML: html)
        #expect(entries == ["序", "本編"])
        let pages = DocumentOutline.pages(
            of: DocumentOutline.headings(inHTML: html), inPageTexts: ["序\n序\n本編", "本編\n本文"], contentsEntries: entries)
        #expect(pages == [0, 1])
    }

    @Test("見出しの直下にある見出しを見分ける")
    func headingsUnderHeadings() {
        let html = "<h1>一</h1>\n<h2>節</h2><p>本文</p><h2>次</h2>"
        #expect(DocumentOutline.headingsUnderHeadings(inHTML: html) == [false, true, false])
    }

    @Test("文書の数字は見出し・文字数・原文の改ページを数える")
    func facts() {
        let body = """
            <h1>題</h1><p>本文</p><div class="page-break" data-syntax="break"></div>
            <div class="page-break" data-syntax="break"></div><hr><nav class="toc"></nav>
            """
        let facts = DocumentFacts(fragment: HTMLFragment(body: body, title: "題"))
        #expect(facts.headings.map(\.text) == ["題"])
        #expect(facts.statistics.characters == 3)
        #expect(facts.pageBreakCounts == [.comment: 2])
        #expect(facts.thematicBreakCount == 1)
        #expect(facts.hasSourceContents)
    }

    @Test("組み込みのセットは 3 つで、名前は言語に従い、id は変わらない")
    func builtInSets() {
        let sets = PrintSettingSet.builtIns(language: "ja")
        #expect(sets.map(\.name) == ["配布資料", "章立ての冊子", "飾りなし"])
        #expect(sets.allSatisfy { $0.isBuiltIn })
        #expect(sets.map(\.id) == PrintSettingSet.builtIns(language: "en").map(\.id))
        #expect(!PrintSettingSet(name: "自分", settings: DocumentSettings()).isBuiltIn)
        #expect(sets[0].layoutID == "a4Duplex")
        #expect(sets[0].furniture == .nameAndDate)
        #expect(sets[0].finish?.toc.mode == .hidden)
        #expect(sets[1].layoutID == "a4BookletA5")
        #expect(sets[1].finish?.breaks.h1 == .rightPage)
        #expect(sets[1].finish?.toc.mode == .front)
        #expect(sets[2].furniture == PageFurniture())
    }

    @Test("設定セットは新しい項目も比べ、PDF には仕上げを持ち込まない")
    func setMatchesNewFields() {
        var options = PrintOptions()
        options.margins = PageMargins(top: 20, left: 10, bottom: 20, right: 10)
        options.furniture = .name
        var finish = PrintFinish()
        finish.breaks.h1 = .page
        let settings = DocumentSettings(layoutID: "a4Single", printOptions: options, printFinish: finish)
        let set = PrintSettingSet(name: "セット", settings: settings)
        #expect(set.matches(settings))
        var changed = settings
        changed.printFinish?.toc.mode = .hidden
        #expect(!set.matches(changed))
        changed = settings
        changed.printOptions?.margins.top = 21
        #expect(!set.matches(changed))
        changed = settings
        changed.printOptions?.furniture = .pageNumber
        #expect(!set.matches(changed))
        #expect(set.applicable(to: .pdf, themeIDs: [], presetIDs: []).finish == nil)
    }

    @Test("古い設定セットの余白とページ番号は 4 辺とヘッダーとして読む")
    func oldSet() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Old","marginsInMillimeters":12,"showsPageNumbers":true}"#
                .utf8)
        let set = try JSONDecoder().decode(PrintSettingSet.self, from: data)
        #expect(set.margins == .uniform(12))
        #expect(set.furniture == .pageNumber)
        #expect(set.finish == nil)
    }

    @Test("リストの続きの本文にある改ページはリストを割らず、後の段落も同じ項目に残る")
    func breakInsideListItem() {
        let html = MarkdownConverter.convert("- 一\n\n  \\newpage\n\n  二\n\n- 三\n").body
        #expect(html.components(separatedBy: "<ul>").count == 2)
        let item = html.components(separatedBy: "</li>")[0]
        #expect(item.contains("class=\"page-break\""))
        #expect(item.contains("二"))
    }

    @Test("字下げのない改ページはリストを終える")
    func breakAfterList() {
        let html = MarkdownConverter.convert("- 一\n\n\\newpage\n\n二\n").body
        #expect(html.components(separatedBy: "</ul>")[0].contains("page-break") == false)
    }

    @Test("中央の欄は左右の文字の場所を残した幅までにする")
    func centerLimit() {
        #expect(PageFurniture.centerLimit(left: 0, right: 0, available: 100, gap: 8) == 100)
        #expect(PageFurniture.centerLimit(left: 10, right: 0, available: 100, gap: 8) == 64)
        #expect(PageFurniture.centerLimit(left: 90, right: 20, available: 100, gap: 8) == 44)
    }

    @Test("印刷オプションのページ番号の有無はヘッダーの設定から読むだけで、中身を消さない")
    func showsPageNumbersReadsOnly() throws {
        var options = PrintOptions()
        #expect(!options.showsPageNumbers)
        options.furniture.topLeft = "{題名}"
        #expect(options.showsPageNumbers)
        let old = Data(#"{"marginsInMillimeters":12,"showsPageNumbers":true}"#.utf8)
        #expect(try JSONDecoder().decode(PrintOptions.self, from: old).furniture == .pageNumber)
    }
}
