import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingsMenuTests {
    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    @Test("ヘルプメニューから文書がなくてもキーと操作の一覧を開ける")
    func keyGuideInHelp() throws {
        let menu = try #require(NSApp.mainMenu?.items.last?.submenu)
        let entries = menu.items.filter { $0.title == localized("Keys and Gestures") }
        #expect(entries.count == 1)
        #expect(entries.first?.isEnabled == true)
    }

    @Test("一覧が案内する印刷キーはファイルメニューの割り当てと一致する")
    func printShortcuts() throws {
        let menu = try #require(NSApp.mainMenu?.items[1].submenu)
        for (titles, flags) in [
            (["Print…", "Print"], NSEvent.ModifierFlags.command),
            (["Print with System Dialog…"], NSEvent.ModifierFlags([.option, .command])),
        ] {
            let item = try #require(menu.items.first { titles.map(localized).contains($0.title) })
            #expect(item.keyEquivalent == "p")
            #expect(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags)
        }
    }

    @Test("メニューバーは表示・文書の順で独立した設定メニューを置かない")
    func topLevelOrder() throws {
        let menu = try #require(NSApp.mainMenu)
        let titles = menu.items.map(\.title)
        try #require(titles.count == 7)
        // System menus use AppKit's translations rather than the application's string catalog.
        for (index, names) in [
            (1, ["File", "ファイル"]), (2, ["Edit", "編集"]), (3, ["View", "表示"]),
            (5, ["Window", "ウインドウ"]), (6, ["Help", "ヘルプ"]),
        ] {
            #expect(names.contains(titles[index]))
        }
        #expect(titles[4] == localized("Document"))
        #expect(!titles.contains(localized("Settings")))
        #expect(!titles.contains(localized("Layout")))
        #expect(!titles.contains(localized("Images")))
    }

    @Test("帯から移した文字選択と固定操作は表示メニューに残る")
    func secondaryViewCommands() throws {
        let menu = try #require(NSApp.mainMenu?.items[3].submenu)
        for key in ["Select Text", "Keep Menu Visible", "Float on Top", "View Options…"] {
            let item = try #require(menu.items.first { $0.title == localized(key) })
            #expect(item.isEnabled)
        }
        let pin = try #require(menu.items.first { $0.title == localized("Keep Menu Visible") })
        #expect(pin.keyEquivalent == "t")
        #expect(pin.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.option, .command])
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
        #expect(
            layouts.items.allSatisfy {
                $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
            })
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

    @Test("設定画面を開く⌘,はアプリ名のメニューの設定だけが持つ")
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
        #expect(["Settings…", "設定…"].contains(owners.first?.title ?? ""))
        #expect(owners.first?.isEnabled == true)
    }
}
