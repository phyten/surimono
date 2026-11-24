import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct RecentFileHistoryTests {
    @Test("履歴の通知がなくても開くたびに最新の順序とURLを使い、消去した次の表示では消去を無効にする")
    func recentSubmenu() throws {
        let first = URL(fileURLWithPath: "/one/sample.md")
        let second = URL(fileURLWithPath: "/two/sample.md")
        var urls = [first]
        var opened: [URL] = []
        let source = RecentDocumentsMenu(urls: { urls }, open: { opened.append($0) }, clear: { urls.removeAll() })
        // A plain AppKit menu shaped like the File menu's first two rows: a hosting menu fills its items later than
        // this test can wait for, and the binding only looks at the header and the row before it.
        let file = NSMenu()
        let openItem = NSMenuItem(
            title: String(localized: "Open…"), action: #selector(NSMenu.cancelTracking), keyEquivalent: "o")
        file.addItem(openItem)
        let header = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        header.submenu = NSMenu()
        file.addItem(header)
        let index = 1
        let menu = try #require(source.bind(in: file, at: index))
        func display() { menu.delegate?.menuNeedsUpdate?(menu) }

        display()
        #expect(menu.items.compactMap { $0.representedObject as? URL } == [first])
        let original = menu.items[0]
        display()
        #expect(menu.items[0] === original)
        urls = [second, first]
        display()
        #expect(menu.items.compactMap { $0.representedObject as? URL } == [second, first])
        #expect(menu.items.map(\.title) == ["sample.md", "sample.md", "", String(localized: "Clear Menu")])
        #expect(menu.items.last?.isEnabled == true)
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        #expect(opened == [second, first])
        menu.performActionForItem(at: menu.numberOfItems - 1)
        display()
        #expect(urls.isEmpty)
        #expect(menu.items.map(\.title) == [String(localized: "Clear Menu")])
        #expect(menu.items.last?.isEnabled == false)
    }

    @Test("古い設定は空で読み込めて保存したパスとブックマークと消去が再起動後も残る")
    func persistence() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.recentFiles.isEmpty)
        preferences.recentFiles.record(.init(path: "/a", bookmark: Data([1, 2])), limit: 5)
        let loaded = AppPreferences(defaults: suite.defaults)
        #expect(loaded.recentFiles.entries == [.init(path: "/a", bookmark: Data([1, 2]))])
        RecentFileHistory(preferences: loaded).clear()
        #expect(AppPreferences(defaults: suite.defaults).recentFiles.isEmpty)
    }

    @Test("システムの一覧が空なら古い順に足し直して消えたファイルを保存からも外す")
    func restoration() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.recentFiles = RecentFiles(entries: [
            .init(path: "/new"), .init(path: "/missing"), .init(path: "/old"),
        ])
        let history = RecentFileHistory(preferences: preferences)
        history.systemURLs = { [] }
        history.systemLimit = { 10 }
        history.exists = { $0.path != "/missing" }
        var noted: [String] = []
        history.noteSystemURL = {
            noted.append($0.path)
            history.record($0)
        }
        history.restoreOnLaunch()
        #expect(noted == ["/old", "/new"])
        #expect(preferences.recentFiles.entries.map(\.path) == ["/new", "/old"])
        #expect(history.visibleURLs.map(\.path) == ["/new", "/old"])
    }

    @Test("システムの一覧があれば足し直さず現在の順序で取り込む")
    func existingSystemHistory() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let history = RecentFileHistory(preferences: preferences)
        history.systemURLs = { [URL(fileURLWithPath: "/new"), URL(fileURLWithPath: "/old")] }
        history.systemLimit = { 2 }
        var writes = 0
        history.noteSystemURL = { _ in writes += 1 }
        history.restoreOnLaunch()
        #expect(writes == 0)
        #expect(preferences.recentFiles.entries.map(\.path) == ["/new", "/old"])
    }

    @Test("移動したファイルをブックマークの場所で復元して重複と上限を適用する")
    func movedFiles() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.recentFiles = RecentFiles(entries: [
            .init(path: "/before"), .init(path: "/after"), .init(path: "/old"),
        ])
        let history = RecentFileHistory(preferences: preferences)
        history.systemURLs = { [] }
        history.systemLimit = { 1 }
        history.locate = { URL(fileURLWithPath: $0.path == "/before" ? "/after" : $0.path) }
        history.exists = { _ in true }
        var noted: [String] = []
        history.noteSystemURL = { noted.append($0.path) }
        history.restoreOnLaunch()
        #expect(noted == ["/after"])
        #expect(preferences.recentFiles.entries.map(\.path) == ["/after"])
    }

    @Test("実際のファイルを移動しても保存したブックマークから新しい場所に戻す")
    func bookmarkFollowsMove() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before.md")
        let after = root.appendingPathComponent("after.md")
        try Data("example".utf8).write(to: before)
        let preferences = AppPreferences(defaults: suite.defaults)
        let history = RecentFileHistory(preferences: preferences)
        history.systemLimit = { 5 }
        history.systemURLs = { [] }
        history.record(before)
        #expect(preferences.recentFiles.entries.first?.bookmark != nil)
        try FileManager.default.moveItem(at: before, to: after)
        var noted: [URL] = []
        history.noteSystemURL = { noted.append($0) }
        history.restoreOnLaunch()
        #expect(noted.map { $0.resolvingSymlinksInPath().path } == [after.resolvingSymlinksInPath().path])
        #expect(preferences.recentFiles.entries.count == 1)
    }

    @Test("保存もシステムも空なら何も足さない")
    func empty() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let history = RecentFileHistory(preferences: AppPreferences(defaults: suite.defaults))
        history.systemURLs = { [] }
        var writes = 0
        history.noteSystemURL = { _ in writes += 1 }
        history.restoreOnLaunch()
        #expect(writes == 0)
    }
}
