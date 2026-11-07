import CoreGraphics
import Testing

@testable import SurimonoCore

struct ThemeCompareLayoutTests {
    private let a4 = CGSize(width: 595, height: 842)

    @Test("4 枚とも 1 枚 280pt 以上で入る窓では、4 列に並べる")
    func fourAcrossInAWideWindow() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 1400, height: 700), paper: a4)
        #expect(layout.columns == 4)
        // (1400 - 2 × 32 - 3 × 24) / 4
        #expect(layout.cardWidth == 316)
    }

    @Test("窓が狭くて 4 列だと 280pt に届かないときは、2 列にして 1 枚を 280pt 以上にする")
    func twoAcrossInANarrowWindow() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 900, height: 900), paper: a4)
        #expect(layout.columns == 2)
        // (900 - 2 × 32 - 24) / 2; the height would allow more.
        #expect(layout.cardWidth == 406)
    }

    @Test("2 列では、1 列目のページと名前とボタンが窓の高さに収まる大きさまでに抑える")
    func aRowOfPagesFitsTheStage() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 900, height: 560), paper: a4)
        #expect(layout.columns == 2)
        // (560 - 16 - 106) / (842 / 595): the row's height is the stage's height.
        #expect(abs(layout.cardWidth - 309.5) < 0.1)
    }

    @Test("2 列でも高さが足りない窓では 280pt を下回らず、収まらない分は縦にスクロールする")
    func neverBelowTheMinimum() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 900, height: 340), paper: a4)
        #expect(layout.columns == 2)
        #expect(layout.cardWidth == 280)
    }

    @Test("幅に余裕があれば、高さが足りなくても 4 列のまま 280pt を保つ")
    func fourAcrossStaysInAShortWindow() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 1400, height: 400), paper: a4)
        #expect(layout.columns == 4)
        #expect(layout.cardWidth == 280)
    }

    @Test("横長の用紙は高さに余裕があるので、同じ窓でも 4 列のまま収まる")
    func landscapePaperKeepsFourAcross() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 1400, height: 500), paper: CGSize(width: 842, height: 595))
        #expect(layout.columns == 4)
        #expect(layout.cardWidth == 316)
    }

    @Test("2 列でも 280pt に届かない幅では 1 列にして、紙が窓からはみ出さないようにする")
    func oneColumnWhenTwoDoNotFit() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 400, height: 900), paper: a4)
        #expect(layout.columns == 1)
        // 400 - 2 × 32
        #expect(layout.cardWidth == 336)
    }

    @Test("窓がごく狭くても、1 枚は 120pt を下回らない")
    func cardsStopShrinking() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 150, height: 900), paper: a4)
        #expect(layout.columns == 1)
        #expect(layout.cardWidth == 120)
    }

    @Test("どんなに広くて高い窓でも、1 枚は 420pt までにする")
    func cardsStopGrowing() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 3000, height: 2000), paper: a4)
        #expect(layout.columns == 4)
        #expect(layout.cardWidth == 420)
    }

    @Test("候補の上限が 3 なら、3 列まで並べる")
    func capacityDecidesTheColumns() {
        let layout = ThemeCompareLayout(stage: CGSize(width: 1400, height: 900), paper: a4, capacity: 3)
        #expect(layout.columns == 3)
        // (1400 - 2 × 32 - 2 × 24) / 3 is 429, but a page is never wider than 420.
        #expect(layout.cardWidth == 420)
    }
}
