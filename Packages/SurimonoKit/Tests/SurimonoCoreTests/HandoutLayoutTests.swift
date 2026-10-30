import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct HandoutLayoutTests {
    @Test(
        "3枚＋メモは順に3枚ずつ並べ最後の空き枠を白紙にする",
        arguments: [
            (0, [[Int?]]()), (1, [[0, nil, nil]]), (3, [[0, 1, 2]]),
            (7, [[0, 1, 2], [3, 4, 5], [6, nil, nil]]),
        ])
    func imposition(count: Int, expected: [[Int?]]) {
        let plan = Imposition.plan(pageCount: count, layout: .a4Handout3)
        #expect(plan.sides.map(\.slots) == expected)
        #expect(plan.sheetCount == expected.count)
        #expect(!plan.isDuplex)
        #expect(plan.sides.allSatisfy { !$0.isBack })
    }

    @Test("3枚＋メモは半裁できない用紙でも片面だけを許す")
    func validation() throws {
        _ = try PrintLayout(id: "letterHandout", kind: .handout3, sheet: .letter, duplex: .none)
        for duplex in [DuplexMode.longEdge, .shortEdge] {
            #expect(throws: PrintLayout.ValidationError.self) {
                try PrintLayout(id: "bad", kind: .handout3, sheet: .a4, duplex: duplex)
            }
        }
        let json = Data(#"{"id":"bad","kind":"handout3","sheet":"a4","duplex":"longEdge"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PrintLayout.self, from: json) }
        let layout = PrintLayout.a4Handout3
        #expect(try JSONDecoder().decode(PrintLayout.self, from: JSONEncoder().encode(layout)) == layout)
        #expect(PrintLayout.presets.last == layout)
        #expect(layout.displayName(language: "ja") == "A4 3枚＋メモ")
        #expect(layout.displayName() == "A4 3-up + Notes")
    }

    @Test("3枚＋メモは向き指定によらずA4縦で余白15mmと8mmの間隔を保つ", arguments: [false, true])
    func geometry(landscape: Bool) throws {
        let layout = PrintLayout.a4Handout3.oriented(landscape)
        let size = layout.sheetSize
        #expect(abs(size.width - 595.2756) < 0.001)
        #expect(abs(size.height - 841.8898) < 0.001)
        let logical = layout.logicalPageSize
        #expect(abs(logical.width - 312.0378) < 0.001)
        #expect(abs(logical.height - 237.1654) < 0.001)
        for (index, y) in [15.0, 106.6666667, 198.3333333].enumerated() {
            let rect = layout.slotRect(at: index)
            #expect(abs(rect.minX * 210 - 15) < 0.001)
            #expect(abs(rect.minY * 297 - y) < 0.001)
            #expect(abs(rect.width * 210 - 110.08) < 0.001)
            #expect(abs(rect.height * 297 - 83.6666667) < 0.001)
        }
        let memo = try #require(layout.memoRect())
        #expect(abs(memo.minX * 210 - 133.08) < 0.001)
        #expect(abs(memo.minY * 297 - 15) < 0.001)
        #expect(abs(memo.width * 210 - 61.92) < 0.001)
        #expect(abs(memo.height * 297 - 267) < 0.001)
        #expect(layout.slotRect(at: 3) == .zero)
        #expect(PrintLayout.a4Single.memoRect() == nil)
    }

    @Test("余白変更で論理ページとメモ欄も変わる")
    func customMargins() throws {
        let options = PrintOptions(marginsInMillimeters: 10)
        let layout = PrintLayout.a4Handout3
        let logical = layout.logicalPageSize(options: options)
        #expect(abs(logical.width - 330.1795) < 0.001)
        #expect(abs(logical.height - 246.6142) < 0.001)
        let memo = try #require(layout.memoRect(options: options))
        #expect(abs(memo.width * 210 - 65.52) < 0.001)
        #expect(abs(memo.height * 297 - 277) < 0.001)
    }
}
