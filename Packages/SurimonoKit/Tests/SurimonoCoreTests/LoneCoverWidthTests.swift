import SurimonoCore
import Testing

struct LoneCoverWidthTests {
    private let book = ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)

    @Test("1 ページ幅の設定では、見開きで表紙を単独で見ている間だけ 1 ページ幅になる")
    func narrowsOnlyAtTheCover() {
        #expect(book.narrowsCover(at: 0, width: .onePage))
        #expect(!book.narrowsCover(at: 1, width: .onePage))
        #expect(!book.narrowsCover(at: 2, width: .onePage))
    }

    @Test("2 ページ幅の設定では表紙でも見開きの幅のまま")
    func twoPagesKeepsTheSpread() {
        #expect(!book.narrowsCover(at: 0, width: .twoPages))
    }

    @Test("表紙を単独にしない見開き・単ページ・スクロールでは幅を変えない")
    func otherLayoutsKeepTheirWidth() {
        var withoutCover = book
        withoutCover.showsCoverAlone = false
        var single = book
        single.layout = .single
        var scrolling = book
        scrolling.transition = .scroll
        #expect(!withoutCover.narrowsCover(at: 0, width: .onePage))
        #expect(!single.narrowsCover(at: 0, width: .onePage))
        #expect(!scrolling.narrowsCover(at: 0, width: .onePage))
    }
}
