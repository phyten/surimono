import Foundation
import SurimonoCore
import Testing

struct RenderedDiagramTests {
    private let diagram = RenderedDiagram(
        number: 2, pageIndex: 1, rect: CGRect(x: 20, y: 40, width: 100, height: 50), svg: "<svg/>")

    @Test("図のあるページで紙の図の内側を押したときだけ選ぶ")
    func hitTest() {
        let point = CGPoint(x: 45, y: 55)
        #expect(RenderedDiagram.hitTest(point, pageIndex: 1, in: [diagram]) == diagram)
        #expect(RenderedDiagram.hitTest(point, pageIndex: 0, in: [diagram]) == nil)
        #expect(RenderedDiagram.hitTest(CGPoint(x: 121, y: 55), pageIndex: 1, in: [diagram]) == nil)
    }

    @Test("保存名は文書の最後の拡張子を外して図の番号を添える")
    func suggestedName() {
        #expect(diagram.suggestedName(documentName: "製本.v2.md") == "製本.v2-diagram-2")
        #expect(diagram.suggestedName(documentName: "Surimono Sample") == "Surimono Sample-diagram-2")
        #expect(diagram.suggestedName(documentName: "") == "Surimono-diagram-2")
    }
}
