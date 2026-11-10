import CoreGraphics
import Foundation
import SurimonoCore
import Testing

struct AdditionalPrintLayoutTests {
    @Test(
        "右とじは左とじの左右だけを交換して白紙位置も保つ",
        arguments: [
            (8, [[Int?]]([[0, 7], [6, 1], [2, 5], [4, 3]])),
            (5, [[Int?]]([[0, nil], [nil, 1], [2, nil], [4, 3]])),
            (12, [[Int?]]([[0, 11], [10, 1], [2, 9], [8, 3], [4, 7], [6, 5]])),
        ])
    func rightBooklet(count: Int, expected: [[Int?]]) {
        let plan = Imposition.plan(pageCount: count, layout: PrintLayout.a3BookletA4.bound(.right))
        #expect(plan.sides.map(\.slots) == expected)
        #expect(plan.sheetCount == expected.count / 2)
        #expect(plan.sides.map(\.isBack) == Array(repeating: [false, true], count: expected.count / 2).flatMap { $0 })
    }

    @Test("4ページ配置は上から左右に読み10ページを3枚に収める")
    func fourUp() {
        let layout = PrintLayout.a4FourUp
        let plan = Imposition.plan(pageCount: 10, layout: layout)
        #expect(plan.sides.map(\.slots) == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, nil, nil]])
        #expect(plan.sheetCount == 3)
        #expect(!plan.isDuplex)
        #expect(layout.slotRect(at: 0) == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(layout.slotRect(at: 1) == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(layout.slotRect(at: 2) == CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(layout.slotRect(at: 3) == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(abs(layout.logicalPageSize.width - 297.638) < 0.01)
        #expect(abs(layout.logicalPageSize.height - 420.945) < 0.01)
        #expect(layout.oriented(true).sheetSize == PaperSize.a4.size)
        #expect(layout.oriented(true).logicalPageSize == layout.logicalPageSize)
    }

    @Test("A4の2ページ配置はA5を横向き用紙に片面で刷る")
    func smallTwoUp() {
        #expect(PrintLayout.a4TwoUp.logicalPageSize == PaperSize.a5.size)
        #expect(abs(PrintLayout.a4TwoUp.sheetSize.width - 841.890) < 0.01)
        #expect(abs(PrintLayout.a4TwoUp.sheetSize.height - 595.276) < 0.01)
        #expect(PrintLayout.a4TwoUp.sentDuplex == .none)
    }

    @Test("Letter系の寸法と冊子の半裁寸法が一致する")
    func letter() {
        #expect(abs(PaperSize.letter.size.width - 612) < 0.001)
        #expect(abs(PaperSize.letter.size.height - 792) < 0.001)
        #expect(abs(PaperSize.tabloid.size.width - 792) < 0.001)
        #expect(abs(PaperSize.tabloid.size.height - 1224) < 0.001)
        #expect(PaperSize.halfLetter.size == CGSize(width: 396, height: 612))
        #expect(PrintLayout.tabloidBookletLetter.logicalPageSize == PaperSize.letter.size)
        #expect(PrintLayout.letterBookletHalfLetter.logicalPageSize == PaperSize.halfLetter.size)
        #expect(PrintLayout.letterDuplex.oriented(true).sentDuplex == .shortEdge)
        #expect(PrintLayout.letterBookletHalfLetter.bound(.right).sentDuplex == .shortEdge)
        let profile = PrinterProfile(rotatesBackSides: [.longEdge: false, .shortEdge: true])
        #expect(profile.rotation(for: PrintLayout.letterBookletHalfLetter.bound(.right).sentDuplex, default: false))
        #expect(!profile.rotation(for: PrintLayout.letterFourUp.sentDuplex, default: true))
    }

    @Test("省紙の選択を系列間で移し冊子のidととじ方は保つ")
    func counterparts() throws {
        #expect(PrintLayout.a4TwoUp.counterpart(in: .b) == .b5TwoUp)
        #expect(PrintLayout.b5FourUp.counterpart(in: .letter) == .letterFourUp)
        #expect(PrintLayout.letterFourUp.counterpart(in: .a) == .a4FourUp)
        let right = PrintLayout.a3BookletA4.bound(.right)
        #expect(right.id == "a3BookletA4")
        #expect(right.counterpart(in: .letter) == PrintLayout.tabloidBookletLetter.bound(.right))
        #expect(throws: PrintLayout.ValidationError.fourUpMustBeSingleSided) {
            try PrintLayout(id: "invalid", kind: .fourUp, sheet: .a4, duplex: .longEdge)
        }
    }

    @Test("初回の系列は地域または既定のLetter用紙から決める")
    func regionalDefault() {
        #expect(PaperSeries.initial(locale: Locale(identifier: "en_US")) == .letter)
        #expect(PaperSeries.initial(locale: Locale(identifier: "ja_JP")) == .a)
        #expect(PaperSeries.initial(locale: Locale(identifier: "en_GB")) == .a)
        #expect(
            PaperSeries.initial(locale: Locale(identifier: "en_CA"), defaultPaperSize: CGSize(width: 612, height: 792))
                == .letter)
    }

    @Test("右とじでは外側内側のヘッダーと余白の奇偶を逆にする")
    func rightFurniture() throws {
        var furniture = PageFurniture()
        furniture.topLeft = "Inside"
        furniture.bottomRight = "{ページ}"
        furniture.swapsOnSpreads = true
        let first = try #require(
            furniture.lines(forPage: 0, pageCount: 8, context: .init(), hasFacingPages: true, rightBound: true))
        #expect(first.top == ["", "", "Inside"])
        #expect(first.bottom == ["1", "", ""])
        let second = try #require(
            furniture.lines(forPage: 1, pageCount: 8, context: .init(), hasFacingPages: true, rightBound: true))
        #expect(second.top == ["Inside", "", ""])
        #expect(second.bottom == ["", "", "2"])
        #expect(PrintLayout.a4BookletA5.bound(.right).swapsSides(onPage: 0))
        #expect(!PrintLayout.a4BookletA5.bound(.right).swapsSides(onPage: 1))
    }

    @Test("新しい文書の未選択のとじ方は保存後も読む向きに従える")
    func automaticBindingRoundTrip() throws {
        let settings = DocumentSettings()
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.bookletBinding == nil)
        #expect(decoded == settings)
    }

    @Test("とじ方のない古い文書記録は左とじで読み新しい選択は往復する")
    func oldRecord() throws {
        var settings = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"layoutID":"a3BookletA4"}"#.utf8))
        #expect(settings.bookletBinding == .left)
        settings.bookletBinding = .right
        #expect(
            try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings)).bookletBinding
                == .right)
        let old = Data(#"{"id":"a3BookletA4","kind":"booklet","sheet":"a3","duplex":"shortEdge"}"#.utf8)
        #expect(try JSONDecoder().decode(PrintLayout.self, from: old).bookletBinding == .left)
    }
}
