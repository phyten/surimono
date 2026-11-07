import CoreGraphics
import Testing

@testable import Surimono

@MainActor
struct PrintStripFoldTests {
    private let widths: [CGFloat] = [120, 70, 80, 60]

    private func visible(_ available: CGFloat, widths: [CGFloat]? = nil, trailing: CGFloat = 130) -> Int {
        PrintStripFold(available: available, itemWidths: widths ?? self.widths, trailingWidth: trailing, spacing: 8)
            .visibleCount
    }

    @Test("4つのメニューと「すべての印刷設定…」が入る幅では、どのメニューも畳まない")
    func everythingFits() {
        #expect(visible(732) == 4)
    }

    @Test("ちょうど入る幅では畳まず、1ポイント狭ければ右のメニューから畳む")
    func boundary() {
        // 120 + 70 + 80 + 60 + 130, and five gaps of 8: one before each menu and one before the button.
        #expect(visible(500) == 4)
        #expect(visible(499) == 3)
    }

    @Test("狭くなるほど右のメニューから順に畳み、左のメニューを先に畳むことはない")
    func foldsFromTheRight() {
        #expect(visible(432) == 3)
        #expect(visible(350) == 2)
        #expect(visible(270) == 1)
    }

    @Test("メニューが1つも入らない幅でも、すべての印刷設定の側は畳まない")
    func trailingStays() {
        #expect(visible(200) == 0)
        #expect(visible(0) == 0)
        #expect(visible(100, trailing: 130) == 0)
    }

    @Test("手前のメニューが長くて入らなければ、その右の短いメニューだけを残すことはしない")
    func keepsAPrefix() {
        #expect(visible(300, widths: [250, 40, 40, 40]) == 0)
    }

    @Test("メニューが無ければ何も数えない")
    func noItems() {
        #expect(visible(732, widths: []) == 0)
    }

    @Test("値を出したメニューが広がると、同じ幅でも入るメニューが減る")
    func valuesWiden() {
        let names: [CGFloat] = [120, 70, 80, 60]
        let values: [CGFloat] = [150, 160, 200, 90]
        #expect(visible(732, widths: names) == 4)
        #expect(visible(732, widths: values) == 3)
    }
}
