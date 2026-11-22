import Foundation
import Testing

@testable import SurimonoFormats

struct RSTBlockBoundaryTests {
    @Test("簡易表の空行は次の列の段落を同じセルに残す")
    func paragraphsInCell() {
        let html = RSTConverter.convert(
            """
            =====  ==========
            Shelf  * Grey
                   * Red

                   Brass ring
            Chest  Spare pin
            =====  ==========
            """
        ).body
        #expect(html.contains("</ul><p>Brass ring</p></td></tr>"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
    }

    @Test("複数行で書いた引用者は一つの署名になる")
    func continuedAttribution() {
        let html = RSTConverter.convert(
            """
            Margin note:

                Ring at dawn.

                -- The keeper
                   of the gate
            """
        ).body
        #expect(html.contains("<p class=\"attribution\">—The keeper\nof the gate</p>"))
    }
}
