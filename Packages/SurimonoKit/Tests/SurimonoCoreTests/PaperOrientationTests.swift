import Foundation
import SurimonoCore
import Testing

struct PaperOrientationTests {
    @Test("上下2アップのスロットは左上基準で上半分と下半分になる")
    func stackedSlotRects() {
        let layout = PrintLayout.a3TwoUp.oriented(true)
        #expect(layout.hasStackedSlots)
        #expect(layout.slotRect(at: 0) == CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(layout.slotRect(at: 1) == CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    @Test("通常は全面を使い左右2アップと冊子は左右の半分を使う")
    func otherSlotRects() {
        #expect(PrintLayout.a4Single.oriented(true).slotRect(at: 0) == CGRect(x: 0, y: 0, width: 1, height: 1))
        for layout in [PrintLayout.a3TwoUp, .a3BookletA4] {
            #expect(!layout.hasStackedSlots)
            #expect(layout.slotRect(at: 0) == CGRect(x: 0, y: 0, width: 0.5, height: 1))
            #expect(layout.slotRect(at: 1) == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        }
    }

    @Test("通常の横向きはA4の用紙と論理ページを入れ替える")
    func normal() {
        let layout = PrintLayout.a4Single.oriented(true)
        #expect(abs(layout.sheetSize.width - 841.89) < 0.1)
        #expect(abs(layout.sheetSize.height - 595.28) < 0.1)
        #expect(layout.logicalPageSize == layout.sheetSize)
        #expect(layout.oriented(false) == .a4Single)
    }

    @Test("横長の2アップはA3縦とA4横になる")
    func stacked() {
        let layout = PrintLayout.a3TwoUp.oriented(true)
        #expect(abs(layout.sheetSize.width - 841.89) < 0.1)
        #expect(abs(layout.sheetSize.height - 1190.55) < 0.1)
        #expect(abs(layout.logicalPageSize.width - 841.89) < 0.1)
        #expect(abs(layout.logicalPageSize.height - 595.28) < 0.1)
    }

    @Test("中綴じは指定した向きに影響されない")
    func booklet() {
        #expect(PrintLayout.a3BookletA4.oriented(true) == .a3BookletA4)
        #expect(PrintLayout.a4BookletA5.oriented(true) == .a4BookletA5)
    }

    @Test(
        "自動は多数決で決まり同数なら先頭に従う",
        arguments: [
            ([true, true], true), ([false, false], false), ([false, true, true], true),
            ([true, false, false], false), ([true, false], true), ([false, true], false), ([], false),
        ])
    func auto(pages: [Bool], expected: Bool) {
        let sizes = pages.map { CGSize(width: $0 ? 200 : 100, height: 150) }
        #expect(PaperOrientation.auto.isLandscape(pageSizes: sizes) == expected)
        #expect(PaperOrientation.landscape.isLandscape(pageSizes: sizes))
        #expect(!PaperOrientation.portrait.isLandscape(pageSizes: sizes))
        #expect(!PaperOrientation.auto.isLandscape(pageSizes: [CGSize(width: 100, height: 100)]))
    }

    @Test("向きを解決したレイアウトはJSONで往復でき古い記録も読める")
    func layoutCoding() throws {
        let layout = PrintLayout.a3TwoUp.oriented(true)
        #expect(try JSONDecoder().decode(PrintLayout.self, from: JSONEncoder().encode(layout)) == layout)
        let old = Data(#"{"id":"a4Single","kind":"normal","sheet":"a4","duplex":"none"}"#.utf8)
        #expect(try JSONDecoder().decode(PrintLayout.self, from: old) == .a4Single)
    }

    @Test("用紙の向きは単独で復元し未知の値でも他の設定を失わない")
    func decoding() throws {
        let decoder = JSONDecoder()
        let saved = try decoder.decode(DocumentSettings.self, from: Data(#"{"paperOrientation":"landscape"}"#.utf8))
        #expect(saved.paperOrientation == .landscape)
        let unknown = try decoder.decode(
            DocumentSettings.self, from: Data(#"{"paperOrientation":"future","themeID":"test"}"#.utf8))
        #expect(unknown.paperOrientation == nil)
        #expect(unknown.themeID == "test")
        #expect(try decoder.decode(DocumentSettings.self, from: Data("{}".utf8)).paperOrientation == nil)
        #expect(try decoder.decode(DocumentSettings.self, from: JSONEncoder().encode(saved)) == saved)
    }
}
