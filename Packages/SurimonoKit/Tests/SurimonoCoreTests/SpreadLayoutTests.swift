import SurimonoCore
import Testing

struct SpreadLayoutTests {
    @Test("見開きは表紙と端数を紙面と同じ側に置き、狭い一覧は読む順に一枚ずつ並ぶ")
    func spreads() {
        func rows(_ count: Int, _ cover: Bool, _ rtl: Bool, _ columns: Int = 2) -> [[Int?]] {
            SpreadLayout.drawerRows(
                pageCount: count, showsCoverAlone: cover,
                direction: rtl ? .rightToLeft : .leftToRight, columns: columns)
        }
        #expect(rows(4, true, false) == [[nil, 0], [1, 2], [3, nil]])
        #expect(rows(4, true, true) == [[0, nil], [2, 1], [nil, 3]])
        #expect(rows(3, false, false) == [[0, 1], [2, nil]])
        #expect(rows(3, false, true) == [[1, 0], [nil, 2]])
        #expect(rows(4, false, true) == [[1, 0], [3, 2]])
        #expect(rows(3, true, false) == [[nil, 0], [1, 2]])
        #expect(rows(4, true, true, 1) == [[0], [1], [2], [3]])
        #expect(rows(0, false, false).isEmpty)
    }

    @Test("上下キーは見開きの同じ列に移り、片方が空ならその行の実ページに移る")
    func verticalFocus() {
        let rows: [[Int?]] = [[0, nil], [2, 1], [nil, 3]]
        #expect(SpreadLayout.verticalNeighbor(of: 1, down: false, in: rows) == 0)
        #expect(SpreadLayout.verticalNeighbor(of: 2, down: true, in: rows) == 3)
        #expect(SpreadLayout.verticalNeighbor(of: 3, down: false, in: rows) == 1)
        #expect(SpreadLayout.verticalNeighbor(of: 0, down: false, in: rows) == 0)
    }

    private func units(
        _ count: Int, layout: ViewOptions.Layout = .spread, cover: Bool, _ direction: ViewOptions.Direction
    ) -> [DisplayUnit] {
        SpreadLayout.units(pageCount: count, layout: layout, showsCoverAlone: cover, direction: direction)
    }

    @Test("左綴じで表紙を単独にすると [ |1] [2|3] [4|5] と組む")
    func leftBoundWithCover() {
        #expect(
            units(5, cover: true, .leftToRight) == [
                .spread(left: nil, right: 1), .spread(left: 2, right: 3), .spread(left: 4, right: 5),
            ])
    }

    @Test("右綴じで表紙を単独にすると [1| ] [3|2] [5|4] と組む")
    func rightBoundWithCover() {
        #expect(
            units(5, cover: true, .rightToLeft) == [
                .spread(left: 1, right: nil), .spread(left: 3, right: 2), .spread(left: 5, right: 4),
            ])
    }

    @Test("表紙を単独にしない左綴じは [1|2] [3|4] と組む")
    func leftBoundWithoutCover() {
        #expect(units(4, cover: false, .leftToRight) == [.spread(left: 1, right: 2), .spread(left: 3, right: 4)])
    }

    @Test("表紙を単独にしない右綴じは [2|1] [4|3] と組む")
    func rightBoundWithoutCover() {
        #expect(units(4, cover: false, .rightToLeft) == [.spread(left: 2, right: 1), .spread(left: 4, right: 3)])
    }

    @Test(
        "最後に余った1ページは本と同じ側に置く",
        arguments: [
            (4, true, ViewOptions.Direction.leftToRight, DisplayUnit.spread(left: 4, right: nil)),
            (4, true, .rightToLeft, .spread(left: nil, right: 4)),
            (5, false, .leftToRight, .spread(left: 5, right: nil)),
            (3, false, .rightToLeft, .spread(left: nil, right: 3)),
        ])
    func leftoverPage(count: Int, cover: Bool, direction: ViewOptions.Direction, last: DisplayUnit) {
        #expect(units(count, cover: cover, direction).last == last)
    }

    @Test("単ページは1ページずつ並べ、表紙と向きの設定に左右されない")
    func singlePages() {
        #expect(units(3, layout: .single, cover: true, .rightToLeft) == [.single(1), .single(2), .single(3)])
    }

    @Test("ページがなければ何も組まない")
    func empty() { #expect(units(0, cover: true, .leftToRight).isEmpty) }

    @Test("ページ番号から、そのページを含む組を探せる")
    func unitContainingPage() {
        let pairs = units(5, cover: true, .rightToLeft)
        #expect(SpreadLayout.unitIndex(containing: 1, in: pairs) == 0)
        #expect(SpreadLayout.unitIndex(containing: 3, in: pairs) == 1)
        #expect(SpreadLayout.unitIndex(containing: 4, in: pairs) == 2)
        #expect(SpreadLayout.unitIndex(containing: 6, in: pairs) == nil)
        #expect(DisplayUnit.spread(left: 3, right: 2).pages == [2, 3])
    }

    @Test("組み地図に入りきるなら、すべての組を見せる")
    func visibleRangeShowsEverythingThatFits() {
        #expect(SpreadLayout.visibleRange(unitCount: 5, current: 4, capacity: 5) == 0..<5)
        #expect(SpreadLayout.visibleRange(unitCount: 3, current: nil, capacity: 8) == 0..<3)
    }

    @Test("入りきらないときは、今の組を真ん中にして見せる")
    func visibleRangeCentresTheCurrentUnit() {
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: 50, capacity: 7) == 47..<54)
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: 50, capacity: 6) == 48..<54)
    }

    @Test("文書の初めと終わりでは、端の組から見せる")
    func visibleRangeStaysWithinTheDocument() {
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: 1, capacity: 7) == 0..<7)
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: 75, capacity: 7) == 69..<76)
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: nil, capacity: 7) == 0..<7)
    }

    @Test("入る数が 0 なら何も見せない")
    func visibleRangeWithoutRoom() {
        #expect(SpreadLayout.visibleRange(unitCount: 76, current: 3, capacity: 0).isEmpty)
        #expect(SpreadLayout.visibleRange(unitCount: 0, current: nil, capacity: 7).isEmpty)
    }

    @Test("ページ表示は単ページを「3 / 12」、見開きを「2–3 / 12」と書く")
    func pageIndicatorText() {
        #expect(PageIndicator.text(pages: [3], pageCount: 12) == "3 / 12")
        #expect(PageIndicator.text(pages: [2, 3], pageCount: 12) == "2–3 / 12")
        #expect(PageIndicator.text(pages: [100, 101], pageCount: 250) == "100–101 / 250")
    }

    @Test(
        "ページ表示の幅は、その文書でいちばん幅を取る表示に合わせる",
        arguments: [
            (9, ViewOptions.Layout.single, "8 / 9"), (12, .single, "88 / 12"), (12, .spread, "88–88 / 12"),
            (250, .spread, "888–888 / 250"), (1500, .spread, "8888–8888 / 1500"),
        ])
    func pageIndicatorWidestText(pageCount: Int, layout: ViewOptions.Layout, widest: String) {
        #expect(PageIndicator.widestText(pageCount: pageCount, layout: layout) == widest)
    }
}
