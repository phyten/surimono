import Foundation
import SurimonoCore
import Testing

struct ViewBandChoicesTests {
    @Test("上だけなら帯は 1 本、上と下に分けるなら 2 本ぶんの場所を取る")
    func bandCounts() {
        #expect(MenuArrangement.top.bandCount == 1)
        #expect(MenuArrangement.split.bandCount == 2)
    }

    @Test("次の変更は今より後のページで、なければ先頭へ戻る")
    func nextChangeWraps() {
        #expect(ChangeNavigation.next(after: 2, in: [7, 1, 7, 4]) == 4)
        #expect(ChangeNavigation.next(after: 4, in: [7, 1, 4]) == 7)
        #expect(ChangeNavigation.next(after: 7, in: [7, 1, 4]) == 1)
    }

    @Test("変更がなければ行き先もない")
    func noChanges() {
        #expect(ChangeNavigation.next(after: 0, in: []) == nil)
    }

    @Test("文書の記録は帯の出し方を覚え、知らない値でも他の設定を失わない")
    func settingsRoundTrip() throws {
        let saved = DocumentSettings(zoom: 2, bandVisibility: .always)
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded.bandVisibility == .always)
        let future = Data(#"{"zoom":2,"bandVisibility":"sometimes","paperSeries":"c"}"#.utf8)
        let tolerant = try JSONDecoder().decode(DocumentSettings.self, from: future)
        #expect(tolerant.zoom == 2)
        #expect(tolerant.bandVisibility == nil)
    }
}
