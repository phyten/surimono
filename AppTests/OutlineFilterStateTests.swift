import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct OutlineFilterStateTests {
    private let entries = [
        OutlineEntry(level: 1, title: "章 不明", pageIndex: nil),
        OutlineEntry(level: 1, title: "章 一", pageIndex: 1),
        OutlineEntry(level: 2, title: "章 二", pageIndex: 3),
    ]

    @Test("見出し七個には欄を出さず八個から出す")
    func threshold() {
        #expect(!OutlineFilterState.showsField(count: 7))
        #expect(OutlineFilterState.showsField(count: 8))
    }

    @Test("選択はページの分かる先頭から動き端で止まりReturnで候補を返して欄を空にする")
    func selectionAndReturn() {
        var state = OutlineFilterState()
        state.setQuery("章", entries: entries)
        #expect(state.matches == [0, 1, 2])
        #expect(state.selection == 1)
        state.move(by: -1)
        #expect(state.selection == 1)
        state.move(by: 1)
        state.move(by: 1)
        #expect(state.selection == 2)
        #expect(state.submit(entries: entries) == entries[2])
        #expect(state.query.isEmpty)
    }

    @Test("入力変更と目次の再読込は先頭へ戻し再読込では入力を保つ")
    func reload() {
        var state = OutlineFilterState()
        state.setQuery("章", entries: entries)
        state.move(by: 1)
        state.reload(entries: entries)
        #expect(state.query == "章" && state.selection == 1)
        state.setQuery("二", entries: entries)
        #expect(state.selection == 2)
    }

    @Test("候補がなければReturnは何もせずEscは入力を消して次に紙へ戻す")
    func emptyAndEscape() {
        var state = OutlineFilterState()
        state.setQuery("なし", entries: entries)
        #expect(state.matches.isEmpty && state.selection == nil)
        #expect(state.submit(entries: entries) == nil && state.query == "なし")
        let cleared = state.escape(entries: entries)
        #expect(!cleared)
        #expect(state.query.isEmpty)
        let returnsToPaper = state.escape(entries: entries)
        #expect(returnsToPaper)
    }

    @Test("今の章を知らない保存配置の補完はデータを失う修復ではない")
    func harmlessUpgrade() {
        let old = BandArrangement.standard(for: .split, knownItems: BandLayout.Item.allCases.filter { $0 != .chapter })
        let result = BandArrangementRepair.repair(StoredBandArrangement(old), for: .split)
        #expect(result.arrangement.unused.contains(.chapter))
        #expect(result.notices.allSatisfy { !$0.losesData })
    }
}
