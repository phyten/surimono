import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct PrintLayoutTests {
    @Test(
        "冊子は手で求めたページ順と白紙位置に一致する",
        arguments: [
            (0, [[Int?]]()),
            (1, [[nil, 0], [nil, nil]]),
            (4, [[3, 0], [1, 2]]),
            (5, [[nil, 0], [1, nil], [nil, 2], [3, 4]]),
            (8, [[7, 0], [1, 6], [5, 2], [3, 4]]),
            (12, [[11, 0], [1, 10], [9, 2], [3, 8], [7, 4], [5, 6]]),
        ])
    func booklet(count: Int, expected: [[Int?]]) {
        let plan = Imposition.plan(pageCount: count, layout: .a3BookletA4)
        #expect(plan.sides.map(\.slots) == expected)
        #expect(plan.sheetCount == expected.count / 2)
        #expect(plan.isDuplex)
        #expect(plan.sides.map(\.isBack) == Array(repeating: [false, true], count: expected.count / 2).flatMap { $0 })
    }

    @Test("2アップの奇数ページは右が白紙になる")
    func twoUp() {
        let plan = Imposition.plan(pageCount: 3, layout: .a3TwoUp)
        #expect(plan.sides.map(\.slots) == [[0, 1], [2, nil]])
        #expect(plan.sheetCount == 2)
        #expect(!plan.isDuplex)
        #expect(plan.sides.allSatisfy { !$0.isBack })
    }

    @Test("通常両面の奇数ページは最後の裏を白紙にする")
    func duplex() {
        let plan = Imposition.plan(pageCount: 3, layout: .a4Duplex)
        #expect(plan.sides.map(\.slots) == [[0], [1], [2], [nil]])
        #expect(plan.sides.map(\.isBack) == [false, true, false, true])
        #expect(plan.sheetCount == 2)
    }

    @Test("通常片面は1ページ1枚になる")
    func single() {
        let plan = Imposition.plan(pageCount: 3, layout: .a4Single)
        #expect(plan.sides.map(\.slots) == [[0], [1], [2]])
        #expect(plan.sheetCount == 3)
        #expect(!plan.isDuplex)
    }

    @Test("0以下のページ数では面を作らない", arguments: PrintLayout.presets)
    func empty(layout: PrintLayout) {
        #expect(Imposition.plan(pageCount: 0, layout: layout).sides.isEmpty)
        #expect(Imposition.plan(pageCount: -1, layout: layout).sheetCount == 0)
    }

    @Test(
        "用紙の縦置き寸法は規格値に一致する",
        arguments: [
            (PaperSize.a3, 297.0, 420.0), (.a4, 210, 297), (.a5, 148, 210),
            (.b4, 257, 364), (.b5, 182, 257), (.letter, 215.9, 279.4), (.tabloid, 279.4, 431.8),
        ])
    func dimensions(paper: PaperSize, width: Double, height: Double) {
        #expect(abs(paper.size.width - width * 72 / 25.4) < 0.001)
        #expect(abs(paper.size.height - height * 72 / 25.4) < 0.001)
    }

    @Test("半裁対応とプリセットの順番を固定する")
    func presets() {
        #expect(PaperSize.allCases.map(\.halved) == [.a4, .a5, nil, .b5, nil, nil, .letter])
        #expect(PrintLayout.presets == [.a4Single, .a4Duplex, .a3BookletA4, .a4BookletA5, .a3TwoUp, .a4Handout3])
        #expect(PrintLayout.a3BookletA4.logicalPageSize == PaperSize.a4.size)
        #expect(PrintLayout.a4BookletA5.logicalPageSize == PaperSize.a5.size)
        #expect(PrintLayout.a3TwoUp.sheetSize.width == PaperSize.a3.size.height)
        #expect(PrintLayout.a4Single.pagesPerSide == 1)
        #expect(PrintLayout.a3TwoUp.pagesPerSide == 2)
        #expect(PrintLayout.presets.allSatisfy { !$0.displayName(language: "ja").isEmpty })
    }

    @Test("不整合なレイアウトを生成とJSON読み込みの両方で拒否する")
    func invalidLayout() throws {
        #expect(throws: PrintLayout.ValidationError.self) {
            try PrintLayout(id: "bad", kind: .booklet, sheet: .a5, duplex: .shortEdge)
        }
        #expect(throws: PrintLayout.ValidationError.self) {
            try PrintLayout(id: "bad", kind: .twoUp, sheet: .a3, duplex: .longEdge)
        }
        let json = Data(#"{"id":"bad","kind":"booklet","sheet":"a4","duplex":"none"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PrintLayout.self, from: json) }
    }

    @Test("レイアウトと印刷オプションはJSONで往復する")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(PrintLayout.a3BookletA4)
        #expect(try JSONDecoder().decode(PrintLayout.self, from: data) == .a3BookletA4)
        let options = PrintOptions()
        let decoded = try JSONDecoder().decode(PrintOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.marginsInMillimeters == 15)
        #expect(!decoded.showsPageNumbers)
        #expect(!decoded.rotatesBackSides)
    }

    @Test("要約は白紙を論理ページ数に含めず全印刷面を数える")
    func summary() {
        let summary = PrintSummary(plan: Imposition.plan(pageCount: 5, layout: .a3BookletA4))
        #expect(summary.logicalPageCount == 5)
        #expect(summary.sheetCount == 2)
        #expect(summary.sideCount == 4)
        #expect(summary.isDuplex)
        #expect(summary.paper == .a3)
    }
}
