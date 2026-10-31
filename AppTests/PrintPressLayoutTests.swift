import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct PrintPressLayoutTests {
    @Test("標準幅では短い向きラベルと長いプリンター名も一段に収まる")
    func singleRow() {
        let layout = PrintPressLayout.Arrangement(width: 974, minimumWidths: [423, 206, 230, 62])
        #expect(!layout.wraps)
        #expect(layout.summaryWidth == 223)
    }

    @Test("長い向きラベルと印刷ボタンが収まらなければ二段になる")
    func longLabels() {
        let layout = PrintPressLayout.Arrangement(width: 974, minimumWidths: [423, 266, 230, 100])
        #expect(layout.wraps)
        #expect(layout.summaryWidth == 620)
    }

    @Test("一段に必要な幅ちょうどでは折り返さず一ポイント狭ければ折り返す")
    func boundary() {
        let widths: [CGFloat] = [423, 206, 230, 62]
        #expect(!PrintPressLayout.Arrangement(width: 957, minimumWidths: widths).wraps)
        #expect(PrintPressLayout.Arrangement(width: 956, minimumWidths: widths).wraps)
    }
}
