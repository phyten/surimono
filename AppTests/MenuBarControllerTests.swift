import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct MenuBarControllerTests {
    @Test("設定がないときはメニューバーに表示し、既定値を書き込まない")
    func defaultVisibility() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = MenuBarController(preferences: preferences, recentURLs: { [] })
        defer { controller.remove() }

        #expect(preferences.showsMenuBarItem)
        #expect(controller.item != nil)
        #expect(suite.defaults.persistentDomain(forName: suite.name)?["showsMenuBarItem"] == nil)
    }

    @Test("設定をオフにするとすぐに消え、次の起動でも非表示のままになる")
    func savedHidden() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = MenuBarController(preferences: preferences, recentURLs: { [] })
        defer { controller.remove() }
        preferences.showsMenuBarItem = false
        #expect(controller.item == nil)

        let restored = AppPreferences(defaults: suite.defaults)
        let reopened = MenuBarController(preferences: restored, recentURLs: { [] })
        defer { reopened.remove() }
        #expect(!restored.showsMenuBarItem)
        #expect(reopened.item == nil)
        #expect(suite.defaults.object(forKey: "showsMenuBarItem") as? Bool == false)
    }

    @Test("保存済みのオンで表示し、設定をオフからオンに戻しても表示する")
    func savedVisible() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "showsMenuBarItem")
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = MenuBarController(preferences: preferences, recentURLs: { [] })
        defer { controller.remove() }

        #expect(controller.item != nil)
        #expect(suite.defaults.object(forKey: "showsMenuBarItem") as? Bool == true)
        preferences.showsMenuBarItem = false
        preferences.showsMenuBarItem = true
        #expect(controller.item != nil)
        #expect(suite.defaults.object(forKey: "showsMenuBarItem") as? Bool == true)
    }

    @Test("メニューバーには冊子のテンプレート画像を使い、読み上げとツールチップにアプリ名を出す")
    func bookletImage() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let controller = MenuBarController(preferences: AppPreferences(defaults: suite.defaults), recentURLs: { [] })
        defer { controller.remove() }

        let button = try #require(controller.item?.button)
        let image = try #require(button.image)
        #expect(image === NSImage(named: "MenuBarIcon"))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "Surimono")
        #expect(button.accessibilityLabel() == "Surimono")
        #expect(button.toolTip == "Surimono")
    }

    @Test("クリップボードの後に履歴の先頭五件を並べ、開く・ストリーミングプレビュー・設定の順で続ける")
    func menuOrder() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let urls = (0..<8).map { URL(fileURLWithPath: "/example/\($0).md") }
        let controller = MenuBarController(preferences: AppPreferences(defaults: suite.defaults), recentURLs: { urls })
        defer { controller.remove() }
        let menu = try #require(controller.item?.menu)
        let commands: [ShortcutOperationID] = [
            .clipboardOpen, .clipboardOpenPrintScreen, .appOpen, .appStreamingPreview, .appSettings,
        ]
        #expect(menu.items.compactMap { $0.representedObject as? String } == commands.map(\.rawValue))
        #expect(menu.items.compactMap { $0.representedObject as? URL } == Array(urls.prefix(5)))
        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title) == commands.prefix(2).map(ShortcutText.name)
                + urls.prefix(5).map(\.lastPathComponent) + commands.suffix(3).map(ShortcutText.name))
        #expect(menu.items.indices.filter { menu.items[$0].isSeparatorItem } == [2, 8])
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.isEnabled)
            #expect(item.target === controller)
            #expect(item.action == NSSelectorFromString(item.representedObject is URL ? "openRecent:" : "run:"))
        }
    }

    @Test("履歴が空になったら次にメニューを開いたとき区切りの間に選べない一行を出す")
    func emptyRecents() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        var recent = [URL(fileURLWithPath: "/example/document.md")]
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = MenuBarController(preferences: preferences, recentURLs: { recent })
        defer { controller.remove() }
        let menu = try #require(controller.item?.menu)

        recent = []
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.count == 8)
        #expect(menu.items.indices.filter { menu.items[$0].isSeparatorItem } == [2, 4])
        let placeholder = try #require(menu.items.dropFirst(3).first)
        #expect(placeholder.title == String(localized: "No Recent Files"))
        #expect(!placeholder.isEnabled)
        #expect(placeholder.action == nil)
    }
}
