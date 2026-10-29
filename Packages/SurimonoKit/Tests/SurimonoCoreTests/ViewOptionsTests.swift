import CoreGraphics
import SurimonoCore
import Testing

struct ViewOptionsTests {
    private let portrait = CGSize(width: 595, height: 842)

    private func pdf(_ pages: Int = 12, size: CGSize? = nil, layout: String? = nil, direction: String? = nil)
        -> ViewOptions
    {
        ViewOptions.defaults(
            for: ViewDefaultsContext(
                kind: .pdf, pageCount: pages, firstPageSize: size ?? portrait, pdfPageLayout: layout,
                pdfDirection: direction))
    }

    @Test("2ページずつのスクロールでは切り替えとスライドだけを選べる")
    func twoPageScrollTransitions() {
        #expect(ViewOptions.transitions(for: .twoPageScroll) == [.instant, .slide])
        #expect(ViewOptions.transitions(for: .spread) == [.scroll, .instant, .slide, .fade, .pageCurl])
    }

    @Test(
        "2ページずつのスクロールで使えない送り方はスライドに直す",
        arguments: [
            ViewOptions.Transition.scroll, .fade, .pageCurl,
        ])
    func normalizeUnavailableTransition(_ transition: ViewOptions.Transition) {
        let options = ViewOptions(
            layout: .twoPageScroll, scrollAxis: .vertical, transition: transition, showsCoverAlone: false)
        #expect(options.normalized().transition == .slide)
    }

    @Test("使える送り方は正規化しても変えない")
    func normalizeKeepsAvailableTransition() {
        let options = ViewOptions(
            layout: .twoPageScroll, scrollAxis: .vertical, transition: .instant, showsCoverAlone: true)
        #expect(options.normalized() == options)
    }

    @Test("連続したスクロールになるのはスクロールの送り方で、2ページずつ以外のとき")
    func continuous() {
        #expect(
            ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
                .isContinuous)
        #expect(
            !ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .slide, showsCoverAlone: false)
                .isContinuous)
        #expect(
            !ViewOptions(layout: .twoPageScroll, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
                .isContinuous)
    }

    @Test("流し込みの文書は単ページの縦の連続スクロールで開く")
    func flowingTextDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .flowingText, pageCount: 30, firstPageSize: portrait))
        #expect(
            options
                == ViewOptions(
                    layout: .single, direction: .leftToRight, scrollAxis: .vertical, transition: .scroll,
                    showsCoverAlone: false))
    }

    @Test("画像の束は見開き・表紙単独・左綴じ・スライドで開く")
    func imageBundleDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .imageBundle, pageCount: 1, firstPageSize: portrait))
        #expect(
            options
                == ViewOptions(
                    layout: .spread, direction: .leftToRight, scrollAxis: .horizontal, transition: .slide,
                    showsCoverAlone: true))
    }

    @Test("1枚の画像は単ページで開く")
    func imageDefaults() {
        let options = ViewOptions.defaults(
            for: ViewDefaultsContext(kind: .image, pageCount: 1, firstPageSize: portrait))
        #expect(options.layout == .single)
        #expect(!options.showsCoverAlone)
    }

    @Test("PDF は見開き・表紙単独・左綴じ・横・スライドで開く")
    func pdfDefaults() {
        #expect(
            pdf()
                == ViewOptions(
                    layout: .spread, direction: .leftToRight, scrollAxis: .horizontal, transition: .slide,
                    showsCoverAlone: true))
    }

    @Test("2ページ以下や横長の PDF は単ページで開く")
    func shortOrLandscapePDF() {
        #expect(pdf(2).layout == .single)
        #expect(pdf(12, size: CGSize(width: 842, height: 595)).layout == .single)
        #expect(pdf(3).layout == .spread)
    }

    @Test("右綴じの PDF は右から左へ表紙単独で開く")
    func rightToLeftPDF() {
        let options = pdf(direction: "R2L")
        #expect(options.direction == .rightToLeft)
        #expect(options.layout == .spread)
        #expect(options.showsCoverAlone)
    }

    @Test("PDF の PageLayout があれば表示の型と表紙の扱いに従う")
    func pdfPageLayout() {
        #expect(pdf(layout: "SinglePage").layout == .single)
        let oneColumn = pdf(layout: "OneColumn")
        #expect(oneColumn.layout == .single && oneColumn.transition == .scroll && oneColumn.scrollAxis == .vertical)
        #expect(!pdf(layout: "TwoPageLeft").showsCoverAlone)
        #expect(pdf(layout: "TwoPageRight").showsCoverAlone)
        let columns = pdf(2, layout: "TwoColumnRight")
        #expect(columns.layout == .spread && columns.transition == .scroll && columns.showsCoverAlone)
    }

    @Test("右綴じの PDF では奇数ページが左にある組みを表紙単独と読む")
    func rightToLeftPageLayout() {
        #expect(pdf(layout: "TwoPageLeft", direction: "R2L").showsCoverAlone)
        #expect(!pdf(layout: "TwoPageRight", direction: "R2L").showsCoverAlone)
    }
}
