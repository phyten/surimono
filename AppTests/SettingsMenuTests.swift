import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SettingsMenuTests {
    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    @Test("設定窓は最初に理想幅で開き、ペインを変えると窓の題名がその翻訳に変わる")
    func paneWindow() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.settingsSection = .printing
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let view = SettingsView(
            preferences: preferences, library: UserLibrary(root: directory),
            arrangementEditor: BandArrangementEditorSession(preferences: preferences))
        let window = SettingsWindowController.makeWindow(for: view)
        defer { window.close() }
        window.orderBack(nil)
        for (section, title) in [(SettingsSection.printing, "Printing"), (.general, "General")] {
            preferences.settingsSection = section
            let expected = localized(title)
            let deadline = ContinuousClock.now + .seconds(5)
            while window.title != expected && ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(window.title == expected)
            #expect(window.frame.width == 860)
            #expect(window.contentRect(forFrameRect: window.frame).height >= 540)
            #expect(window.contentMinSize == NSSize(width: 820, height: 540))
        }
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
        #expect(!preferences.defaultShowsOnAllSpaces)
        #expect(!preferences.defaultAlwaysOnTop && preferences.defaultBandVisibility == .always)
        #expect(preferences.defaultTypeface == .style)
        #expect(preferences.defaultTextScale == 1)
        #expect(preferences.defaultPaperOrientation == .auto)
        preferences.defaultReadingDirection = .rightToLeft
        preferences.defaultScrollAxis = .horizontal
        preferences.defaultShowsCoverAlone = false
        preferences.loneCoverWidth = .twoPages
        preferences.defaultAlwaysOnTop = true
        preferences.defaultShowsOnAllSpaces = true
        preferences.defaultBandVisibility = .always
        preferences.defaultTypeface = .latex
        preferences.defaultTextScale = 1.25
        preferences.defaultPaperOrientation = .landscape
        let restored = AppPreferences(defaults: suite.defaults)
        #expect(
            restored.viewDefaults
                == ViewDefaultPreferences(
                    direction: .rightToLeft, scrollAxis: .horizontal, showsCoverAlone: false))
        #expect(restored.loneCoverWidth == .twoPages)
        #expect(restored.defaultShowsOnAllSpaces)
        #expect(restored.defaultAlwaysOnTop && restored.defaultBandVisibility == .always)
        #expect(restored.defaultTypeface == .latex)
        #expect(restored.defaultTextScale == 1.25)
        preferences.defaultTextScale = 1.13
        preferences.margin = 12.5
        #expect(AppPreferences(defaults: suite.defaults).defaultTextScale == 1.13)
        #expect(AppPreferences(defaults: suite.defaults).margin == 12.5)
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
            let item = try #require(menu.items.first { titles.map { localized($0) }.contains($0.title) })
            #expect(item.keyEquivalent == "p")
            #expect(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags)
        }
    }

    @Test("メニューバーは表示・文書の順で独立した設定メニューを置かない")
    func topLevelOrder() throws {
        let menu = try #require(NSApp.mainMenu)
        let titles = menu.items.map(\.title)
        try #require(titles.count == 7)
        for (index, key) in [(1, "File"), (2, "Edit"), (3, "View"), (5, "Window"), (6, "Help")] {
            #expect(titles[index] == ViewerMainMenu.standardTitle(key))
        }
        #expect(titles[4] == localized("Document"))
        #expect(!titles.contains(localized("Settings")))
        #expect(!titles.contains(localized("Layout")))
        #expect(!titles.contains(localized("Images")))
    }

    @Test("文字選択と窓の固定操作は表示メニューにあり、ツールバーを常に表示は⌥⌘Tで切り替わる")
    func secondaryViewCommands() throws {
        let menu = try #require(NSApp.mainMenu?.items[3].submenu)
        menu.update()
        for key in ["Select Text", "Always Show Toolbar", "Float on Top", "Show on All Spaces", "View Options…"] {
            _ = try #require(menu.items.first { $0.title == localized(key) })
        }
        let pin = try #require(menu.items.first { $0.title == localized("Always Show Toolbar") })
        #expect(pin.keyEquivalent == "t")
        #expect(pin.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.option, .command])
    }

    @Test("表示メニューは単ページと見開きの順で⌥⌘1と⌥⌘2を割り当てる")
    func viewLayoutOrderAndShortcuts() throws {
        let menu = try #require(NSApp.mainMenu?.items[3].submenu)
        menu.update()
        let entries = menu.items.filter { [localized("Single Page"), localized("Spread")].contains($0.title) }
        #expect(entries.map(\.title) == [localized("Single Page"), localized("Spread")])
        #expect(entries.map(\.keyEquivalent) == ["1", "2"])
        #expect(
            entries.map { $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) }
                == [[.option, .command], [.option, .command]])
    }

    @Test(
        "表示の既定値は従来の文字列を読み込み変更後も同じ値で保存する",
        arguments: [("single", ViewOptions.Layout.single), ("spread", .spread)])
    func storedViewLayout(storedValue: String, layout: ViewOptions.Layout) {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(storedValue, forKey: "defaultViewLayout")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.defaultViewLayout == layout)
        preferences.defaultViewLayout = nil
        #expect(suite.defaults.string(forKey: "defaultViewLayout") == nil)
        preferences.defaultViewLayout = layout
        #expect(suite.defaults.string(forKey: "defaultViewLayout") == storedValue)
        #expect(AppPreferences(defaults: suite.defaults).defaultViewLayout == layout)
    }

    @Test("文書メニューに印刷レイアウト・スタイル・リセット・再読み込みをまとめ、一覧の項目は束と合本の窓だけに出す")
    func documentItems() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == localized("Document") }?.submenu)
        #expect(
            menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
                == [
                    "Print Layout", "Setting Sets", "Print Settings…", "Choose Style…", "Add Documents…",
                    "Reset Document Settings", "Reload",
                ].map { localized($0) })
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

    @Test("文書メニューには印刷の設定がひとつだけある")
    func printSettingsItem() throws {
        let menu = try #require(NSApp.mainMenu?.items.first { $0.title == localized("Document") }?.submenu)
        menu.update()
        let entries = menu.items.filter { $0.title == localized("Print Settings…") }
        #expect(entries.count == 1)
    }

    @Test("文書がないときは表示と文書の操作を選べず、設定セットは管理だけ選べる")
    func availabilityWithoutDocument() throws {
        let menu = try #require(NSApp.mainMenu?.items[4].submenu)
        let sets = try #require(menu.items.first { $0.title == localized("Setting Sets") }?.submenu)
        for key in ["Save Current Settings…", "Manage Setting Sets…"] {
            _ = try #require(sets.items.first { $0.title == localized(key) })
        }
        let visibility = MenuSnapshot.Visibility(model: nil, preferences: nil)
        let needsDocument: [ShortcutOperationID] = [
            .viewSelectText, .viewToolbarAlways, .viewFloatOnTop, .viewShowOnAllSpaces, .viewOptions,
            .viewSingle, .viewSpread, .printSettings, .settingSetSave,
        ]
        for operation in needsDocument {
            #expect(!ShortcutDispatcher.isAvailable(operation, model: nil, visibility: visibility))
        }
        #expect(ShortcutDispatcher.isAvailable(.settingSetManage, model: nil, visibility: visibility))
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
        #expect(owners.first?.title == ViewerMainMenu.standardTitle("Settings…"))
        #expect(owners.first?.isEnabled == true)
    }
}
