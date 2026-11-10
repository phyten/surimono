import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingsMenuTests {
    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    @Test("新しい表示・ウィンドウ・印刷の既定値は保存され再読み込みできる")
    func viewerDefaultsPersistence() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.defaultReadingDirection == nil)
        #expect(preferences.defaultScrollAxis == nil)
        #expect(preferences.defaultShowsCoverAlone == nil)
        #expect(preferences.loneCoverWidth == .onePage)
        #expect(!preferences.defaultAlwaysOnTop && preferences.defaultBandVisibility == .always)
        #expect(preferences.defaultTextScale == 1)
        #expect(preferences.defaultPaperOrientation == .auto)
        preferences.defaultReadingDirection = .rightToLeft
        preferences.defaultScrollAxis = .horizontal
        preferences.defaultShowsCoverAlone = false
        preferences.loneCoverWidth = .twoPages
        preferences.defaultAlwaysOnTop = true
        preferences.defaultBandVisibility = .always
        preferences.defaultTextScale = 1.25
        preferences.defaultPaperOrientation = .landscape
        let restored = AppPreferences(defaults: suite.defaults)
        #expect(
            restored.viewDefaults
                == ViewDefaultPreferences(
                    direction: .rightToLeft, scrollAxis: .horizontal, showsCoverAlone: false))
        #expect(restored.loneCoverWidth == .twoPages)
        #expect(restored.defaultAlwaysOnTop && restored.defaultBandVisibility == .always)
        #expect(restored.defaultTextScale == 1.25)
        #expect(restored.defaultPaperOrientation == .landscape)
        restored.defaultShowsCoverAlone = true
        #expect(AppPreferences(defaults: suite.defaults).defaultShowsCoverAlone == true)
        restored.defaultReadingDirection = nil
        restored.defaultScrollAxis = nil
        restored.defaultShowsCoverAlone = nil
        #expect(AppPreferences(defaults: suite.defaults).viewDefaults == ViewDefaultPreferences())
    }

    @Test("不正な新しい既定値は従来の動作に戻る")
    func invalidViewerDefaults() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        for key in ["defaultReadingDirection", "defaultScrollAxis", "loneCoverWidth", "defaultPaperOrientation"] {
            suite.defaults.set("unknown", forKey: key)
        }
        suite.defaults.set(9, forKey: "defaultTextScale")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.viewDefaults == ViewDefaultPreferences())
        #expect(preferences.loneCoverWidth == .onePage)
        #expect(preferences.defaultTextScale == 1)
        #expect(preferences.defaultPaperOrientation == .auto)
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
        for key in ["Select Text", "Always Show Toolbar", "Float on Top", "View Options…"] {
            let item = try #require(menu.items.first { $0.title == localized(key) })
            #expect(item.isEnabled)
        }
        let pin = try #require(menu.items.first { $0.title == localized("Always Show Toolbar") })
        #expect(pin.keyEquivalent == "t")
        #expect(pin.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.option, .command])
    }

    @Test("文書メニューに印刷レイアウト・スタイル・リセット・再読み込みをまとめ、一覧の項目は束と合本の窓だけに出す")
    func documentItems() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == localized("Document") }?.submenu)
        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                == [
                    "Print Layout", "Choose Style…", "Add Documents…", "Reset Document Settings", "Reload",
                ].map(localized))
        let layouts = try #require(menu.items.first?.submenu)
        // The six cards keep ⌘1 to ⌘6; the layouts that save paper on the same sheet follow without a key.
        let items = layouts.items.filter { !$0.isSeparatorItem }
        #expect(items.prefix(6).map(\.keyEquivalent) == ["1", "2", "3", "4", "5", "6"])
        #expect(items.dropFirst(6).allSatisfy { $0.keyEquivalent.isEmpty })
        #expect(
            items.prefix(6).allSatisfy {
                $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
            })
    }

    @Test("表示メニューの設定セットは文書がなくても保存と管理の項目を有効に保つ")
    func settingSetCommands() throws {
        let menu = try #require(NSApp.mainMenu?.items[3].submenu)
        let sets = try #require(menu.items.first { $0.title == localized("Setting Sets") }?.submenu)
        for key in ["Save Current Settings…", "Manage Setting Sets…"] {
            let item = try #require(sets.items.first { $0.title == localized(key) })
            #expect(item.isEnabled)
        }
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
