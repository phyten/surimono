import Testing

@testable import Surimono

@MainActor
struct SettingsSearchTests {
    @Test("アイコンと部品の表示を検索するとツールバーの配置の先頭行が見つかる", arguments: ["icon", "アイコン", "Parts", "部品の表示"])
    func bandNames(query: String) {
        let labels = ["Parts": "部品の表示", "Icons and Names": "アイコンと名前", "Icons Only": "アイコンのみ"]
        let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { labels[$0] ?? $0 })
        #expect(hits.rows.contains { $0.section == .toolbarArrangement && $0.anchor == "Parts" })
    }

    @Test("一般の検索結果は画面と同じ順で、見出しで検索すると配下の各行を強調する")
    func generalGroups() {
        let documents = [
            "When a Binder Is Down to One Document", "Reload When the File Changes", "After a File Is Saved",
            "Changed Places", "Changed Text",
        ]
        let window = ["Corners", "Float on Top", "Show on All Spaces"]
        let updates = [
            "Check for Updates Automatically", "When an Update Is Found",
            "Updates are unavailable in development builds.",
        ]
        let names = ["After a Document Opens": "文書を開いたあと", "Window": "ウインドウ", "Updates": "アップデート"]
        let groups = [("文書を開いたあと", documents), ("ウインドウ", window), ("アップデート", updates)]
        for (query, expected) in groups {
            let hits = SettingsCatalogue.search(query, in: SettingsCatalogue.rows, localize: { names[$0] ?? $0 })
            #expect(hits.bestSection(keeping: .view) == .general)
            #expect(hits.rows.filter { $0.section == .general }.map(\.anchor) == expected)
        }
        let all = SettingsCatalogue.search("General", in: SettingsCatalogue.rows, localize: { $0 })
        let first = ["Language", "Appearance", "Show in Menu Bar"]
        #expect(all.rows.filter { $0.section == .general }.map(\.anchor) == first + documents + window + updates)
    }

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
