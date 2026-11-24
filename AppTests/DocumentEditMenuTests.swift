import AppKit
import Testing

@testable import Surimono

@MainActor
struct DocumentEditMenuTests {
    @Test("実際のファイルメニューは原本を変更する項目を作らず、共有を一つだけ持つ")
    func readOnlyFileMenu() throws {
        let main = try #require(NSApp.mainMenu)
        let file = try #require(main.item(at: 1)?.submenu)
        let edits: Set<Selector> = [
            #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
            #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
            #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)),
            #selector(NSDocument.lock(_:)), #selector(NSDocument.unlock(_:)),
        ]
        // Include hidden rows: an invisible Save/Save As still owns an action and can acquire a shortcut.
        let actions = ShortcutMenuBaselineTests.items(main).compactMap(\.action)
        #expect(edits.isDisjoint(with: actions))
        let shares = file.items.filter { $0.title == String(localized: "Share") }
        let share = try #require(shares.count == 1 ? shares.first : nil)
        #expect(!share.isHidden && share.submenu != nil && share.image == nil)
        #expect(!NSDocumentController.shared.allowsAutomaticShareMenu)
        #expect(file.items.allSatisfy { $0.title != "NSMenuItem" })
    }

    @Test("追跡中は最近使った項目を入れ替えず、親を閉じた後で同じ行を移す")
    func recentFilesWaitForEndOfTracking() async throws {
        let main = try #require(NSApp.mainMenu)
        let file = try #require(main.item(at: 1)?.submenu)
        let recent = try #require(
            file.items.first { $0.identifier?.rawValue == RecentDocumentsMenu.identifier }?.submenu)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let history = RecentFileHistory(preferences: AppPreferences(defaults: suite.defaults))
        let first = URL(fileURLWithPath: "/first/menu.md")
        let second = URL(fileURLWithPath: "/second/menu.md")
        var urls = [first]
        history.systemURLs = { urls }
        let previous = RecentFileHistory.shared
        RecentFileHistory.shared = history
        defer {
            RecentFileHistory.shared = previous
            recent.delegate?.menuNeedsUpdate?(recent)
        }
        recent.delegate?.menuNeedsUpdate?(recent)
        let before = recent.items
        try #require(before.first?.representedObject as? URL == first)

        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: main)
        center.post(name: NSMenu.didBeginTrackingNotification, object: file)
        urls = [second, first]
        center.post(name: RecentFileHistory.systemListChanged, object: nil)
        recent.delegate?.menuNeedsUpdate?(recent)
        #expect(recent.items == before)
        center.post(name: NSMenu.didEndTrackingNotification, object: file)
        recent.delegate?.menuNeedsUpdate?(recent)
        #expect(recent.items == before)
        // Some versions send only the root end after moving from File into its submenu.
        center.post(name: NSMenu.didBeginTrackingNotification, object: recent)
        center.post(name: NSMenu.didEndTrackingNotification, object: main)
        try await ShortcutMenuBaselineTests.waitForMenu { recent.items.first?.representedObject as? URL == second }
        #expect(recent.items.compactMap { $0.representedObject as? URL } == [second, first])
        #expect(recent.item(at: 1) === before.first && recent.items.last === before.last)
    }

    @Test("実メニューバーの七つのメニューに従来の項目が同じ順序で並ぶ")
    func installedMenuOrder() throws {
        let main = try #require(NSApp.mainMenu)
        let menus = main.items.compactMap(\.submenu)
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Surimono"
        func localized(_ key: String) -> String {
            Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        func native(_ key: String) -> String {
            Bundle.main.localizedString(forKey: key, value: key, table: "MainMenu")
        }
        func named(_ key: String) -> String { String(format: native(key), appName) }
        let expectedMenus = [
            appName, native("File"), native("Edit"), native("View"), localized("Document"), native("Window"),
            native("Help"),
        ]
        try #require(menus.map(\.title) == expectedMenus)
        #expect(NSApp.windowsMenu === menus[5] && NSApp.helpMenu === menus[6])
        #expect(NSApp.servicesMenu === menus[0].item(withTitle: native("Services"))?.submenu)

        // AppKit adds different Search, Services, input-method and window rows on each OS.
        let owner = try #require(menus[1].delegate as? ViewerMainMenu)
        func visible(_ menu: NSMenu) -> [String] {
            menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && owner.installedItems.contains($0) }.map(\.title)
        }

        for menu in menus { menu.delegate?.menuNeedsUpdate?(menu) }
        let content = ShortcutDispatcher.shared.menus.menuState.snapshot.content
        var app = [named("About %@")]
        if content.visibility.canCheckUpdates { app.append(localized("Check for Updates…")) }
        app += [
            native("Settings…"), native("Services"), named("Hide %@"), native("Hide Others"), native("Show All"),
            named("Quit %@"),
        ]
        #expect(visible(menus[0]) == app)

        var file = [
            "Open…", "Open Recent", "Open from Clipboard", "Open Clipboard on the Print Screen", "Open from URL…",
        ]
        if content.visibility.hasHistory {
            file += ["Reopen Closed Clipboard Document", "Recently Closed Clipboard Documents"]
        }
        file += ["Streaming Preview"]
        if !content.recentBinders.isEmpty { file += ["Recent Binders"] }
        var fileTitles = file.map(localized) + [native("Close")]
        if content.visibility.canSaveAsFile { fileTitles.append(localized("Save as File…")) }
        fileTitles += ["Share", content.printing ? "Print" : "Print…", "Print with System Dialog…", "Export"].map(
            localized)
        #expect(visible(menus[1]) == fileTitles)
        // File is the ownership regression: an unexpected system row must also fail this baseline.
        let renderedFile = DebugMenuDump.visibleFileRows(menus[1], modifiers: [])
            .map { $0.isSeparatorItem ? "|" : $0.title }
        var fileWithDividers = file.map(localized) + ["|", native("Close")]
        if content.visibility.canSaveAsFile { fileWithDividers.append(localized("Save as File…")) }
        fileWithDividers += ["|", localized("Share"), "|"]
        fileWithDividers += [content.printing ? "Print" : "Print…", "Print with System Dialog…", "Export"].map(
            localized)
        #expect(renderedFile == fileWithDividers)

        let standardEdit = ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All"].map(native)
        let edit = ["Copy as HTML", "Copy as Rich Text", "Find…", "Find Next", "Find Previous"].map(localized)
        #expect(visible(menus[2]) == standardEdit + edit)
        for title in standardEdit { #expect(menus[2].item(withTitle: title)?.target == nil) }
        var view = [
            content.showsPaper ? "Show as Web" : "Show as Paper", "Show as Slides", "Single Page", "Spread",
            "View Options…", "Go to Page…", "Check Writing", "Back", "Forward", "Bookmark This Page",
            "Next Bookmark", "Previous Bookmark", "Increase Text Size", "Decrease Text Size", "Original Text Size",
        ]
        if content.composition != nil { view.append("LaTeX Layout") }
        if content.typeface != nil { view.append("Typeface") }
        view += [
            "Zoom In", "Zoom Out", "Fit to Window", "Select Text", "Always Show Toolbar", "Float on Top",
            "Show on All Spaces",
        ]
        #expect(visible(menus[3]) == view.map(localized))

        var document = ["Print Layout", "Setting Sets", "Print Settings…", "Choose Style…"]
        if content.visibility.canOpenBinder { document.append("Open as Binder") }
        document.append("Add Documents…")
        if content.visibility.hasBinder {
            document.append("Binder")
        } else if content.visibility.hasImages {
            document.append("Images")
        }
        document += ["Reset Document Settings", "Reload"]
        #expect(visible(menus[4]) == document.map(localized))
        #expect(visible(menus[5]) == ["Minimize", "Zoom", "Bring All to Front"].map(native))
        #expect(
            visible(menus[6])
                == ["Getting Started with Surimono", "Open Sample Document", "Keys and Gestures"].map(localized))
    }
}
