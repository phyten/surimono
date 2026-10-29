import SurimonoCore
import Testing

struct SpreadLayoutTests {
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

    @Test("2ページずつのスクロールは見開きと同じ組みになる")
    func twoPageScrollPairsLikeSpreads() {
        #expect(
            units(5, layout: .twoPageScroll, cover: true, .leftToRight) == [
                .spread(left: nil, right: 1), .spread(left: 2, right: 3), .spread(left: 4, right: 5),
            ])
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
}
