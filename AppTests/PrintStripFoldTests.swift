import CoreGraphics
import Testing

@testable import Surimono

@MainActor
struct PrintStripFoldTests {
    private let widths: [CGFloat] = [120, 70, 80, 60]

    private func form(_ available: CGFloat, widths: [CGFloat]? = nil) -> PrintStripFold.Form {
        PrintStripFold(
            available: available, itemWidths: widths ?? self.widths, detailsWidth: 130, detailsIconWidth: 30,
            spacing: 8
        ).form
    }

    @Test("4つのメニューと「すべての印刷設定…」が入る幅では、どれも畳まない")
    func everythingFits() {
        #expect(form(732) == .full)
    }

    @Test("ちょうど入る幅では畳まず、1ポイント狭ければ「すべての印刷設定…」を絵だけにする")
    func detailsBecomeAnIcon() {
        // 120 + 70 + 80 + 60 + 130, and five gaps of 8: one before each menu and one before the button.
        #expect(form(500) == .full)
        #expect(form(499) == .iconDetails)
        // With the icon of 30 instead of the label of 130.
        #expect(form(400) == .iconDetails)
    }

    @Test("絵だけにしても入らなければ、メニューを1つのメニューにまとめる")
    func menusCombine() {
        #expect(form(399) == .combined)
        #expect(form(200) == .combined)
        #expect(form(0) == .combined)
    }

    @Test("値を出したメニューが広がると、同じ幅でも先に畳む")
    func valuesWiden() {
        #expect(form(732, widths: [120, 70, 80, 60]) == .full)
        #expect(form(732, widths: [150, 160, 200, 90]) == .iconDetails)
        #expect(form(600, widths: [150, 160, 200, 90]) == .combined)
    }

    @Test("メニューが無ければ「すべての印刷設定…」だけを測る")
    func noItems() {
        #expect(form(138, widths: []) == .full)
        #expect(form(137, widths: []) == .iconDetails)
    }
}
