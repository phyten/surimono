import Testing

@testable import Surimono

@MainActor
struct SettingsSearchTests {
    @Test("印刷とprintは区分名に一致し、余白は部品名より印刷の設定行を優先する", arguments: ["印刷", "print", "余白"])
    func printing(query: String) {
        let names = ["Printing": "印刷", "Margins": "余白", "Text Margins": "本文の余白", "Print…": "印刷…"]
        let results = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { names[$0] ?? $0 })
        #expect(results.bestSection(keeping: .keyboardShortcuts) == .printing)
        #expect(results.bestSection(keeping: .toolbarArrangement) == .printing)
    }

    @Test("項目名の完全一致・前方一致・部分一致の順で選び、同順位は現在の区分かサイドバーの先頭を使う")
    func labelRank() {
        let rows = [
            SettingsSearchRow(.general, "My color"), SettingsSearchRow(.styles, "Color scheme"),
            SettingsSearchRow(.view, "Color"), SettingsSearchRow(.printing, "Color"),
        ]
        func best(_ n: Int, _ section: SettingsSection) -> SettingsSection? {
            SettingsCatalogue.search("color", in: Array(rows.prefix(n)), localize: { $0 }).bestSection(keeping: section)
        }
        #expect(best(2, .general) == .styles)
        #expect(best(3, .styles) == .view)
        #expect(best(4, .printing) == .printing)
        #expect(best(4, .general) == .view)
    }

    @Test("検索中に読者が選んだ区分は、自動選択と同じ区分でもクリア後に残る")
    func explicitChoice() {
        var selection = SettingsSearchSelection()
        selection.begin(in: .html)
        selection.pick(.printing)
        #expect(selection.finish() == .printing)
    }

    @Test("自動で移動しただけなら検索前の区分に戻り、前回の手動選択を次の検索へ持ち越さない")
    func automaticChoice() {
        var selection = SettingsSearchSelection()
        selection.begin(in: .general)
        selection.pick(.styles)
        _ = selection.finish()
        selection.begin(in: .html)
        #expect(selection.finish() == .html)
    }
}
