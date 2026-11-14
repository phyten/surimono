import Foundation
import Testing

@testable import SurimonoRendering

struct FootnoteGeometryTests {
    @Test("予約帯を上から切り取り下の本文を累積した高さだけ上へ動かす")
    func segments() throws {
        let layout = try #require(
            FootnoteGeometry(
                lower: 20, upper: 820, bands: [.init(bottom: 600, height: 40), .init(bottom: 300, height: 60)]))
        #expect(
            layout.segments == [
                .init(lower: 640, upper: 820, shift: 0),
                .init(lower: 360, upper: 600, shift: 40),
                .init(lower: 20, upper: 300, shift: 100),
            ])
        #expect(layout.shift(at: 500) == 40)
        #expect(layout.shift(at: 200) == 100)
    }

    @Test("重なる帯や用紙の外の帯は切り取らない")
    func invalid() {
        #expect(FootnoteGeometry(lower: 0, upper: 800, bands: [.init(bottom: 700, height: 110)]) == nil)
        #expect(
            FootnoteGeometry(
                lower: 0, upper: 800, bands: [.init(bottom: 600, height: 50), .init(bottom: 620, height: 40)]) == nil)
    }

    @Test("脚注を下の余白の上に番号順に積み余りを本文との間に残す")
    func stacking() {
        #expect(FootnoteGeometry.noteBottoms(heights: [20, 30], bottom: 40, reserved: 66) == [70, 40])
        #expect(FootnoteGeometry.noteBottoms(heights: [80], bottom: 40, reserved: 66) == nil)
    }

    @Test("文字倍率を打ち消して予約高さを切り上げる")
    func scaledReserve() {
        #expect(FootnoteGeometry.reservePixels(height: 48, pixelsPerPoint: 1.25, textScale: 2) == 30)
        #expect(FootnoteGeometry.reservePixels(height: 49, pixelsPerPoint: 1.25, textScale: 1) == 62)
    }
}
