import SurimonoCore
import Testing

struct PageChaptersTests {
    private let headings = [
        DocumentHeading(level: 1, text: "題"), DocumentHeading(level: 2, text: "甲"),
        DocumentHeading(level: 3, text: "節"), DocumentHeading(level: 2, text: "乙"),
        DocumentHeading(level: 2, text: "丙"),
    ]

    @Test("章の前は空で途中から始まる章を引き継ぎ同じページの最後の章を使う")
    func chapters() {
        #expect(
            PageChapters.titles(headings: headings, pages: [0, 1, 2, 3, 3], pageCount: 5)
                == ["", "甲", "甲", "丙", "丙"])
    }

    @Test("見出しがない文書とページが分からない章は空になる")
    func missing() {
        #expect(PageChapters.titles(headings: [], pages: [], pageCount: 2) == ["", ""])
        #expect(PageChapters.titles(headings: headings, pages: [], pageCount: 2) == ["", ""])
    }

    @Test("前付けの目次と白紙には章を出さず本文と対応する")
    func frontMatter() {
        let plan = FinishedPagePlan(bodyPageCount: 3, contentsPageCount: 1, rightPageStarts: [0])
        #expect(
            PageChapters.titles(headings: headings, pages: [0, 1, nil, 2, nil], pageCount: 3, plan: plan)
                == ["", "", "", "甲", "乙"])
    }

    @Test("章末のノートには章を出さず次の本文で章を引き継ぐ")
    func notes() {
        let plan = FinishedPagePlan(
            bodyPageCount: 3, contentsPageCount: 1, rightPageStarts: [],
            notes: .init(placement: .chapterEnd, layoutKind: .normal, chapterEnds: [1]))
        #expect(
            PageChapters.titles(headings: headings, pages: [0, 0, nil, 2, nil], pageCount: 3, plan: plan)
                == ["", "甲", "甲", "", "乙", ""])
    }

    @Test("章が空の欄には空白や区切りだけを残さない", arguments: [" — {章} — ", " {章} | ", " {章} / "])
    func emptySlot(template: String) {
        var furniture = PageFurniture()
        furniture.topCenter = template
        #expect(furniture.lines(forPage: 0, pageCount: 1, context: .init(), hasFacingPages: false)?.top[1] == "")
    }
}
