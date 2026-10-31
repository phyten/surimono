import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingsMenuTests {
    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    @Test("メニューバーは表示・文書・設定の順で旧レイアウトと画像を独立させない")
    func topLevelOrder() throws {
        let menu = try #require(NSApp.mainMenu)
        let titles = menu.items.map(\.title)
        try #require(titles.count == 8)
        // System menus use AppKit's translations rather than the application's string catalog.
        for (index, names) in [
            (1, ["File", "ファイル"]), (2, ["Edit", "編集"]), (3, ["View", "表示"]),
            (6, ["Window", "ウインドウ"]), (7, ["Help", "ヘルプ"]),
        ] {
            #expect(names.contains(titles[index]))
        }
        #expect(titles[4] == localized("Document"))
        #expect(titles[5] == localized("Settings"))
        #expect(!titles.contains(localized("Layout")))
        #expect(!titles.contains(localized("Images")))
    }

    @Test("設定メニューは既定値と番号と全設定を決めた順序に並べる")
    func settingsItems() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == localized("Settings") }?.submenu)
        let keys: [String?] = [
            "Scroll Sensitivity", "Default Page Turn", "New Document View", nil,
            "Join Pages in Single-Page Scrolling", "Page Numbers in View Mode", "Page Numbers in Print", nil,
            "Default Print Layout", "Default Margins", "Default Style", nil, "All Settings…",
        ]
        #expect(menu.items.map { $0.isSeparatorItem ? nil : $0.title } == keys.map { $0.map(localized) })
        let sensitivity = try #require(menu.items.first?.submenu)
        #expect(sensitivity.items.map(\.title) == ["Low", "Normal", "High"].map(localized))
        let turn = try #require(menu.items.first { $0.title == localized("Default Page Turn") }?.submenu)
        #expect(turn.items.count == ViewOptions.Transition.allCases.count + 1)
        #expect(turn.items.first?.title == localized("Automatic (Match Document)"))
        let view = try #require(menu.items.first { $0.title == localized("New Document View") }?.submenu)
        #expect(view.items.map(\.title) == ["Automatic (Match Document)", "Spread", "Single Page"].map(localized))
        let margins = try #require(menu.items.first { $0.title == localized("Default Margins") }?.submenu)
        #expect(margins.items.map(\.title) == ["0 mm", "10 mm", "15 mm", "20 mm", "25 mm"])
        #expect(menu.items.last?.keyEquivalent == "")
    }

    @Test("文書メニューに印刷レイアウト・スタイル・画像・リセット・再読み込みをまとめる")
    func documentItems() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == localized("Document") }?.submenu)
        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == [
                    "Print Layout", "Choose Style…", "Images", "Reset Document Settings", "Reload",
                ].map(localized))
        let layouts = try #require(menu.items.first?.submenu)
        #expect(layouts.items.map(\.keyEquivalent) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test("表示の既定値は保存され未設定や不正な値なら自動に戻る")
    func preferencesPersistence() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.viewDefaults == ViewDefaultPreferences())
        preferences.defaultViewLayout = .spread
        preferences.defaultPageTurn = .wipe
        preferences.defaultJoinsPages = false
        let restored = AppPreferences(defaults: suite.defaults)
        #expect(restored.viewDefaults == ViewDefaultPreferences(layout: .spread, transition: .wipe, joinsPages: false))
        restored.defaultViewLayout = nil
        restored.defaultPageTurn = nil
        let automatic = AppPreferences(defaults: suite.defaults)
        #expect(automatic.defaultViewLayout == nil)
        #expect(automatic.defaultPageTurn == nil)
        #expect(!automatic.defaultJoinsPages)
        suite.defaults.set("unknown", forKey: "defaultViewLayout")
        suite.defaults.set("unknown", forKey: "defaultPageTurn")
        let fallback = AppPreferences(defaults: suite.defaults)
        #expect(fallback.defaultViewLayout == nil)
        #expect(fallback.defaultPageTurn == nil)
    }

    @Test("⌘, はアプリのメニューの設定だけが持ち、設定メニューの全設定は持たない")
    func settingsShortcutIsUnique() throws {
        let menu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let owners = items(menu).filter {
            $0.keyEquivalent == ","
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }
        #expect(owners.count == 1)
        #expect(owners.first?.menu === menu.items.first?.submenu)
    }
}
