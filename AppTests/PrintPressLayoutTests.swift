import CoreGraphics
import Testing

@testable import Surimono

struct PrintPressLayoutTests {
    /// Six cards 80 wide with 2 between them, a paper row of 28, a result of three lines, and the buttons of a typical
    /// printer name: the printer and PDF buttons take 130 to 205, Print is 62 square.
    private func parts(
        summaryWidth: CGFloat = 330, summaryHeight: @escaping (CGFloat) -> CGFloat = { $0 >= 200 ? 48 : 64 }
    )
        -> PrintPressArrangement.Parts
    {
        PrintPressArrangement.Parts(
            paperRow: CGSize(width: 250, height: 28), cardsWidth: 490,
            cardsHeight: { width in
                let perRow = max(1, Int((width + 2) / 82))
                let rows = (6 + perRow - 1) / perRow
                return CGFloat(rows) * 88 + CGFloat(rows - 1) * 4
            }, summaryWidth: summaryWidth, summaryHeight: summaryHeight, actionsWidth: 130...205, actionsHeight: 62,
            button: CGSize(width: 62, height: 62))
    }

    @Test("幅760の窓では、選ぶ側を左、結果とボタンを右に並べ、全体の高さは120になる")
    func besideAtMinimumWidth() {
        let layout = PrintPressArrangement(width: 732, parts: parts())
        #expect(layout.form == .beside)
        #expect(layout.paperRow == CGRect(x: 0, y: 0, width: 250, height: 28))
        #expect(layout.cards == CGRect(x: 0, y: 32, width: 490, height: 88))
        #expect(layout.summary == CGRect(x: 507, y: 0, width: 225, height: 48))
        #expect(layout.actions == CGRect(x: 507, y: 58, width: 155, height: 62))
        #expect(layout.button == CGRect(x: 670, y: 58, width: 62, height: 62))
        #expect(layout.rule == CGRect(x: 498, y: 0, width: 1, height: 120))
        #expect(layout.size == CGSize(width: 732, height: 120))
    }

    @Test("幅1000の窓でも結果の列は必要以上に広げず、印刷ボタンは右端に置く")
    func besideWhenWide() {
        let layout = PrintPressArrangement(width: 972, parts: parts())
        #expect(layout.form == .beside)
        #expect(layout.summary == CGRect(x: 642, y: 0, width: 330, height: 48))
        #expect(layout.actions == CGRect(x: 697, y: 58, width: 205, height: 62))
        #expect(layout.button.maxX == 972)
        #expect(layout.size.height == 120)
    }

    @Test("結果の文が短いときは、右の列をボタンの幅に合わせて右端に寄せる")
    func shortResultFitsTheButtons() {
        let layout = PrintPressArrangement(width: 972, parts: parts(summaryWidth: 100))
        #expect(layout.summary.minX == 697)
        #expect(layout.summary.width == 275)
        #expect(layout.actions.minX == layout.summary.minX)
    }

    @Test("結果の文が長くて右の列が背高になれば、ボタンを下に置いたまま全体が高くなり、線も伸びる")
    func tallResultGrowsTheBar() {
        let layout = PrintPressArrangement(width: 732, parts: parts(summaryHeight: { _ in 100 }))
        #expect(layout.size.height == 170)
        #expect(layout.button.maxY == 170)
        #expect(layout.rule.height == 170)
    }

    @Test("左右に並べられる最小の幅は、カードの列と線とボタンの最小幅の和で、1ポイント狭ければ二段になる")
    func boundary() {
        // 490 for the cards, 8 + 1 + 8 around the rule, and 130 + 8 + 62 for the buttons.
        #expect(PrintPressArrangement(width: 707, parts: parts()).form == .beside)
        #expect(PrintPressArrangement(width: 706, parts: parts()).form == .stacked)
    }

    @Test("用紙の行がカードの列より広いときは、広い方の幅を選ぶ側の幅として左右に並べられるかを決める")
    func wideChoicesRow() {
        var wide = parts()
        wide.paperRow = CGSize(width: 520, height: 28)
        // 520 for the paper row, 8 + 1 + 8 around the rule, and 130 + 8 + 62 for the buttons.
        #expect(PrintPressArrangement(width: 737, parts: wide).form == .beside)
        #expect(PrintPressArrangement(width: 736, parts: wide).form == .stacked)
        #expect(PrintPressArrangement(width: 737, parts: wide).summary.minX >= 520 + 17)
    }

    @Test("二段のときは結果とボタンが選ぶ側の下の1行になり、線を出さず、左端が3つの行でそろう")
    func stackedInARow() {
        let layout = PrintPressArrangement(width: 600, parts: parts())
        #expect(layout.form == .stacked)
        #expect(layout.rule == .zero)
        #expect([layout.paperRow.minX, layout.cards.minX, layout.summary.minX] == [0, 0, 0])
        #expect(layout.cards == CGRect(x: 0, y: 32, width: 600, height: 88))
        #expect(layout.summary == CGRect(x: 0, y: 135, width: 313, height: 48))
        #expect(layout.actions == CGRect(x: 325, y: 128, width: 205, height: 62))
        #expect(layout.button == CGRect(x: 538, y: 128, width: 62, height: 62))
        #expect(layout.size == CGSize(width: 600, height: 190))
    }

    @Test("狭い窓ではカードが折り返し、結果の下にボタンを置く")
    func stackedInAColumn() {
        let layout = PrintPressArrangement(width: 340, parts: parts())
        #expect(layout.form == .stacked)
        // Two rows of cards, then the result, then the buttons at the right.
        #expect(layout.cards == CGRect(x: 0, y: 32, width: 340, height: 180))
        #expect(layout.summary == CGRect(x: 0, y: 220, width: 340, height: 48))
        #expect(layout.button == CGRect(x: 278, y: 276, width: 62, height: 62))
        #expect(layout.actions == CGRect(x: 65, y: 276, width: 205, height: 62))
        #expect(layout.size == CGSize(width: 340, height: 338))
    }

    @Test("どの形でも、印刷ボタンは右端にあり、ボタンの列はその左に並び、どの部品も幅の内に収まる", arguments: [340, 500, 600, 707, 732, 972, 1400])
    func staysInside(width: CGFloat) {
        let layout = PrintPressArrangement(width: width, parts: parts())
        #expect(layout.button.maxX == width)
        #expect(layout.actions.maxX <= layout.button.minX)
        for frame in [layout.paperRow, layout.cards, layout.summary, layout.actions, layout.button] {
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= width)
        }
        #expect(layout.size.width == width)
    }
}
