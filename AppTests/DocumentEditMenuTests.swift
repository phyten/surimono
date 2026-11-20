import AppKit
import Testing

@testable import Surimono

@MainActor
struct DocumentEditMenuTests {
    /// Listed here rather than read from the implementation, so that an action dropped there fails the tests.
    private static let documentEdits: [(String, Selector)] = [
        ("Save", #selector(NSDocument.save(_:))), ("Save As…", #selector(NSDocument.saveAs(_:))),
        ("Save To…", #selector(NSDocument.saveTo(_:))), ("Duplicate", #selector(NSDocument.duplicate(_:))),
        ("Rename…", #selector(NSDocument.rename(_:))), ("Move To…", #selector(NSDocument.move(_:))),
        ("Revert To Saved", #selector(NSDocument.revertToSaved(_:))),
        ("Browse All Versions…", #selector(NSDocument.browseVersions(_:))),
        ("Lock", #selector(NSDocument.lock(_:))), ("Unlock", #selector(NSDocument.unlock(_:))),
    ]

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @Test("文書を書き換える項目を隠してショートカットも止め、閉じると共有は残す")
    func hidesDocumentEdits() {
        let menu = NSMenu()
        let edits = Self.documentEdits.map { item($0.0, $0.1) }
        for edit in edits { edit.allowsKeyEquivalentWhenHidden = true }
        let close = item("Close", #selector(NSWindow.performClose(_:)))
        let share = item("Share", nil)
        share.submenu = NSMenu()
        for entry in [close] + edits + [.separator(), share] { menu.addItem(entry) }
        DocumentEditMenu().hideItems(in: menu)
        #expect(edits.allSatisfy { $0.isHidden && !$0.allowsKeyEquivalentWhenHidden })
        #expect(!close.isHidden)
        #expect(!share.isHidden)
    }

    @Test("保存・複製の代替表示を解除し、キー文字と閉じるの代替は保つ")
    func hiddenEditsAreNotAlternates() {
        let menu = NSMenu()
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .option, .shift]
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "S")
        duplicate.keyEquivalentModifierMask = [.command, .shift]
        duplicate.isAlternate = true
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let closeAll = NSMenuItem(
            title: "Close All", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .option]
        closeAll.isAlternate = true
        for entry in [close, closeAll, saveAs, duplicate] { menu.addItem(entry) }
        DocumentEditMenu().hideItems(in: menu)
        for edit in [saveAs, duplicate] {
            #expect(edit.isHidden)
            #expect(!edit.isAlternate)
            #expect(!edit.allowsKeyEquivalentWhenHidden)
            #expect(edit.keyEquivalent.lowercased() == "s")
        }
        #expect(closeAll.isAlternate && !closeAll.isHidden && closeAll.keyEquivalent == "w")
        #expect(close.keyEquivalent == "w")
    }

    @Test("アプリのどのメニューにも、隠した項目の代わりに出る項目がない")
    func appMenuLeavesNoWayToDocumentEdits() async {
        // Include the initial pass over the assembled main menu.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        func all(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + all($0.submenu) } }
        let versionsTitle = Bundle(for: NSDocument.self).localizedString(
            forKey: "Revert To", value: "Revert To", table: "MenuCommands")
        func visit(_ menu: NSMenu?) {
            var previous: NSMenuItem?
            for item in menu?.items ?? [] {
                // An open menu shows an alternate in place of a hidden primary.
                if item.isAlternate, let previous { #expect(!previous.isHidden || item.isHidden, "\(item.title)") }
                if previous?.action == #selector(NSDocument.revertToSaved(_:)), let submenu = item.submenu,
                    [versionsTitle, "Revert To", "バージョンを戻す"].contains(item.title)
                        || submenu.items.contains(where: { $0.action == #selector(NSDocument.browseVersions(_:)) })
                {
                    #expect(item.isHidden && !item.isAlternate)
                    #expect(!item.allowsKeyEquivalentWhenHidden)
                }
                previous = item
                visit(item.submenu)
            }
        }
        let actions = Set(Self.documentEdits.map(\.1))
        let edits = all(NSApp.mainMenu).filter { $0.action.map(actions.contains) == true }
        #expect(!edits.isEmpty)
        for edit in edits {
            #expect(edit.isHidden, "\(edit.title)")
            #expect(!edit.isAlternate, "\(edit.title)")
            #expect(!edit.allowsKeyEquivalentWhenHidden, "\(edit.title)")
        }
        visit(NSApp.mainMenu)
    }

    @Test("追跡中に復帰のすぐ後ろに追加されたバージョンの小メニューだけを同期的に隠す", arguments: ["Revert To", "バージョンを戻す"])
    func hidesRevertSubmenu(title: String) {
        let main = NSMenu()
        main.addItem(NSMenuItem())
        let group = NSMenuItem()
        let file = NSMenu()
        group.submenu = file
        main.addItem(group)
        let updates = MenuUpdates(
            state: MenuState(), root: { main }, model: { nil }, preferences: { nil },
            lifecycle: NotificationCenter(), apply: { _ in })
        updates.start()
        defer { updates.stop() }
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: main)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: main) }
        file.addItem(item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))))
        let revertTo = item(title, NSSelectorFromString("submenuAction:"))
        revertTo.submenu = NSMenu()
        file.addItem(revertTo)
        #expect(revertTo.isHidden)
        let writes = updates.hider.writes.counts
        let export = item(String(localized: "Export"), nil)
        export.submenu = NSMenu()
        file.insertItem(export, at: 1)
        #expect(!export.isHidden && updates.hider.writes.counts == writes)
    }

    @Test("復帰のすぐ後ろの書き出すメニューは表示したままにする")
    func preservesExportAfterRevert() {
        let menu = NSMenu()
        menu.addItem(item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))))
        let export = item(String(localized: "Export"), nil)
        export.submenu = NSMenu()
        menu.addItem(export)
        DocumentEditMenu().hideItems(in: menu)
        #expect(!export.isHidden)
    }

    @Test("アプリのメニューでは文書を書き換える項目が隠れていて、閉じるは見える")
    func appMenuHidesDocumentEdits() {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let actions = Set(Self.documentEdits.map(\.1))
        let edits = items.filter { $0.action.map(actions.contains) == true }
        #expect(!edits.isEmpty)
        #expect(edits.allSatisfy { $0.isHidden })
        let close = items.first { $0.action == #selector(NSWindow.performClose(_:)) }
        #expect(close?.isHidden == false)
    }

    @Test("実メニューにあとから足された編集項目や表示に戻された編集項目を同期的に隠す")
    func hidesItemsAddedLater() throws {
        let file = try #require(NSApp.mainMenu?.items.dropFirst().first?.submenu)
        let move = item("Move To…", #selector(NSDocument.move(_:)))
        file.addItem(move)
        defer { file.removeItem(move) }
        #expect(move.isHidden)
        move.isHidden = false
        #expect(move.isHidden)
    }
}
