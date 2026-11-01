import Foundation
import SurimonoCore
import Testing

struct PageSizesTests {
    let portrait = CGSize(width: 595, height: 842)
    let landscape = CGSize(width: 842, height: 595)

    @Test("縦3枚と横1枚では最も多い縦の寸法を返す")
    func majority() {
        #expect(PageSizes.representative([landscape, portrait, portrait, portrait]) == portrait)
    }

    @Test("同数の寸法は先に出た方を返す")
    func tie() {
        #expect(PageSizes.representative([landscape, portrait, portrait, landscape]) == landscape)
    }

    @Test("幅と高さの1pt以内の誤差を同じ寸法として数える")
    func tolerance() {
        #expect(PageSizes.representative([landscape, portrait, CGSize(width: 596, height: 841)]) == portrait)
    }

    @Test("回転後の表示寸法で縦横を数える", arguments: [90, 270, -90])
    func rotation(angle: Int) {
        let rotated = PageSizes.displayed(landscape, rotation: angle)
        #expect(rotated == portrait)
        #expect(PageSizes.representative([landscape, rotated, portrait]) == portrait)
    }

    @Test("ページがなければゼロの寸法を返す")
    func empty() {
        #expect(PageSizes.representative([]) == .zero)
    }

    @Test("横スクロールは幅と高さに収め縦スクロールは幅だけに合わせ拡大しない", arguments: ViewOptions.Layout.allCases)
    func continuousScaling(layout: ViewOptions.Layout) {
        let reference = CGSize(width: 300, height: 500)
        let sizes = [
            reference, reference, reference, CGSize(width: 600, height: 250),
            CGSize(width: 150, height: 1000), CGSize(width: 600, height: 1000), CGSize(width: 150, height: 250),
        ]
        for axis in ViewOptions.ScrollAxis.allCases {
            let plan = ViewPageLayout(
                pageCount: sizes.count,
                options: ViewOptions(layout: layout, scrollAxis: axis, transition: .scroll, showsCoverAlone: false),
                hasLogicalMargins: false, showsNumbers: false, pageSizes: sizes)
            let expected: [CGFloat] = axis == .vertical ? [1, 1, 1, 0.5, 1, 0.5, 1] : [1, 1, 1, 0.5, 0.5, 0.5, 1]
            for index in sizes.indices { #expect(plan.scale(at: index) == expected[index]) }
        }
    }

    @Test("連続表示の混在寸法だけがコピーのキーに縮小を含める")
    func copyKey() {
        var options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        func plan(_ sizes: [CGSize]) -> ViewPageLayout {
            ViewPageLayout(
                pageCount: sizes.count, options: options, hasLogicalMargins: false, showsNumbers: false,
                pageSizes: sizes)
        }
        let sizes = [portrait, landscape, portrait, CGSize(width: 300, height: 1684)]
        let vertical = plan(sizes).documentKey(margin: 0)
        #expect(vertical.requiresCopy)
        #expect(!plan([portrait, portrait]).documentKey(margin: 0).requiresCopy)
        options.scrollAxis = .horizontal
        #expect(plan(sizes).documentKey(margin: 0) != vertical)
        options.transition = .instant
        #expect(!plan(sizes).documentKey(margin: 0).requiresCopy)
    }
}
