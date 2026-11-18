import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct MenuBarControllerTests {
    @Test("メニューバーの項目は既定で非表示で設定に合わせて追加と削除を行う")
    func visibility() {
        let suite = BandTestDefaultsSuite()
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = MenuBarController(preferences: preferences, recentURLs: { [] })
        defer { controller.remove() }
        #expect(controller.item == nil)
        preferences.showsMenuBarItem = true
        #expect(AppPreferences(defaults: suite.defaults).showsMenuBarItem)
        #expect(controller.item?.button?.image?.isTemplate == true)
        preferences.showsMenuBarItem = false
        #expect(controller.item == nil)
        #expect(!AppPreferences(defaults: suite.defaults).showsMenuBarItem)
    }

    @Test("メニューを開くたびに最近の先頭八件と開く操作だけを順番に並べる")
    func menuOrder() {
        let preferences = AppPreferences(defaults: BandTestDefaultsSuite().defaults)
        let urls = (0..<10).map { URL(fileURLWithPath: "/example/\($0).md") }
        var recent = urls
        let controller = MenuBarController(preferences: preferences, recentURLs: { recent })
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let commands: [ShortcutOperationID] = [
            .clipboardOpen, .clipboardOpenPrintScreen, .appStreamingPreview, .appOpen, .appSettings,
        ]
        #expect(menu.items.compactMap { $0.representedObject as? String } == commands.map(\.rawValue))
        #expect(menu.items.compactMap { $0.representedObject as? URL } == Array(urls.prefix(8)))
        #expect(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title) == commands.prefix(3).map(ShortcutText.name)
                + urls.prefix(8).map(\.lastPathComponent) + commands.suffix(2).map(ShortcutText.name))
        #expect(menu.items.indices.filter { menu.items[$0].isSeparatorItem } == [3, 12])
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.target === controller)
            #expect(item.action == NSSelectorFromString(item.representedObject is URL ? "openRecent:" : "run:"))
        }
        recent = []
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.count == 6 && menu.items[3].isSeparatorItem)
    }
}
