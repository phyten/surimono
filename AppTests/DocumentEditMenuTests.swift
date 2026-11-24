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

    @Test("組み上がったファイルメニューが追跡中に取り付けられても標準の開くと履歴を隠す")
    func prebuiltFileMenu() {
        let main = NSMenu()
        main.addItem(NSMenuItem())
        let file = NSMenu()
        let own = file.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        let system = file.addItem(
            withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenuItem()
        let children = NSMenu()
        children.addItem(
            withTitle: "Clear", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = children
        file.addItem(recent)
        let item = NSMenuItem()
        item.submenu = file
        main.addItem(item)
        let note = Notification(name: NSMenu.didAddItemNotification, object: main, userInfo: ["NSMenuItemIndex": 1])
        DocumentEditMenu(canScan: { false }, isTracking: { true }).hideNotifiedItem(note, in: main, main: main)
        #expect(!own.isHidden && system.isHidden && recent.isHidden)
    }

    @Test("文書共有の小メニューは初回と組み直した後も標準の共有先を使い、仮の題名は隠さない")
    func documentSharing() throws {
        let share = DocumentShareMenu()
        let file = NSMenu()
        let row = file.addItem(withTitle: String(localized: "Share"), action: nil, keyEquivalent: "")
        row.image = DocumentShareMenu.glyph
        let standard = NSDocumentController.shared.standardShareMenuItem()
        let expected = try #require(standard.submenu?.delegate)
        for _ in 0..<2 {
            let seed = NSMenu()
            row.submenu = seed
            share.bind(row)
            let installed = try #require(row.submenu)
            let delegate = try #require(installed.delegate)
            #expect(installed !== seed && installed.supermenu === file)
            #expect(type(of: delegate) == type(of: expected))
            #expect(row.isEnabled && !row.isHidden && row.target === installed && row.action == standard.action)
            share.bind(row)
            #expect(row.submenu === installed && DocumentShareMenu.isInstalled(on: row))
        }

        let unfinished = NSMenuItem()
        file.addItem(unfinished)
        DocumentEditMenu().hideItems(in: file)
        #expect(!unfinished.isHidden)
    }

    @Test("追跡中に標準の共有が先に来ても後から来ても自前の共有と一区切りだけが残る", arguments: [true, false])
    func sharesDuringOpening(systemFirst: Bool) throws {
        let main = NSMenu()
        main.addItem(NSMenuItem())
        let file = NSMenu()
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let updates = MenuUpdates(
            state: MenuState(), root: { main }, model: { nil }, preferences: { nil },
            lifecycle: NotificationCenter(), apply: { _ in })
        updates.start()
        defer { updates.stop() }
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: main)
        defer { center.post(name: NSMenu.didEndTrackingNotification, object: main) }

        let own = NSMenuItem(title: "自前", action: nil, keyEquivalent: "")
        own.setAccessibilityIdentifier(DocumentShareMenu.identifier)
        own.submenu = NSMenu()
        let template = NSDocumentController.shared.standardShareMenuItem()
        let native: NSMenuItem
        if systemFirst {
            native = template
        } else {
            // A new wrapper can arrive with only the factory's identifier, before its submenu.
            native = NSMenuItem()
            native.identifier = try #require(template.identifier)
        }
        native.title = "標準"
        let first = NSMenuItem.separator()
        let second = NSMenuItem.separator()
        let last = NSMenuItem.separator()
        for row in [
            NSMenuItem(title: "閉じる", action: nil, keyEquivalent: ""), first,
            systemFirst ? native : own, second, systemFirst ? own : native, last,
            NSMenuItem(title: "印刷", action: nil, keyEquivalent: ""),
        ] {
            file.addItem(row)
            if row === native { #expect(native.isHidden) }
        }
        #expect(native.isHidden && !own.isHidden && DocumentShareMenu.isInstalled(on: own))
        native.isHidden = false
        #expect(native.isHidden)
        let visible = file.items.filter { !$0.isHidden }
        #expect(visible.count == 5 && visible[2] === own)
        #expect(visible[1].isSeparatorItem && visible[3].isSeparatorItem)

        // SwiftUI releases the external submenu before assigning it to its new header.
        // Check before the setter: AppKit raises an Objective-C exception on a second parent.
        let moving = try #require(own.submenu)
        own.submenu = nil
        try #require(moving.supermenu == nil, "共有の切り離し通知中に元の見出しへ接続し直した")
        native.submenu = moving
        #expect(native.submenu === moving && native.isHidden)
        #expect(own.submenu !== moving && DocumentShareMenu.isInstalled(on: own) && !own.isHidden)

        let unrelated = NSMenuItem(title: String(localized: "Share"), action: nil, keyEquivalent: "")
        unrelated.submenu = NSMenu()
        file.insertItem(unrelated, at: file.index(of: native))
        #expect(!unrelated.isHidden && !DocumentShareMenu.isInstalled(on: unrelated))
        #expect(!first.isHidden && !second.isHidden && !last.isHidden)
    }

    @Test("ファイルの表示直前の記録は元の委譲先の更新後に表示行だけを読む")
    func openingDump() throws {
        final class Delegate: NSObject, NSMenuDelegate {
            var updates = 0
            func menuNeedsUpdate(_ menu: NSMenu) { updates += 1 }
            func menuWillOpen(_ menu: NSMenu) { menu.items[0].isEnabled = true }
        }
        let file = NSMenu()
        let row = file.addItem(withTitle: "共有", action: nil, keyEquivalent: "")
        row.isEnabled = false
        file.addItem(.separator())
        let hidden = file.addItem(withTitle: "保存", action: nil, keyEquivalent: "")
        hidden.isHidden = true
        let original = Delegate()
        file.delegate = original
        var visible: [NSMenuItem] = []
        var beforeClose: [NSMenuItem] = []
        let observer = FileOpeningObserver(
            file,
            didOpen: { menu in
                visible = DebugMenuDump.visibleFileRows(menu, modifiers: [])
                #expect(row.isEnabled)
            },
            beforeClose: { menu in beforeClose = DebugMenuDump.visibleFileRows(menu, modifiers: []) })
        file.delegate?.menuNeedsUpdate?(file)
        file.delegate?.menuWillOpen?(file)
        #expect(original.updates == 1 && visible == [row])
        hidden.isHidden = false
        withExtendedLifetime(observer) { file.delegate?.menuDidClose?(file) }
        #expect(beforeClose == file.items)
        #expect(file.delegate === original)
    }

    @Test("標準の開くと後から履歴消去が付くサブメニューだけを追加時に隠す")
    func systemOpenItems() throws {
        let file = try #require(NSApp.mainMenu?.items.dropFirst().first?.submenu)
        let open = NSMenuItem(
            title: "System", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        open.allowsKeyEquivalentWhenHidden = true
        file.addItem(open)
        defer { file.removeItem(open) }
        #expect(open.isHidden && !open.allowsKeyEquivalentWhenHidden)
        let recent = NSMenuItem(title: "System history", action: nil, keyEquivalent: "")
        let children = NSMenu()
        recent.submenu = children
        file.addItem(recent)
        defer { file.removeItem(recent) }
        children.addItem(
            withTitle: "Clear", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        #expect(recent.isHidden && !recent.allowsKeyEquivalentWhenHidden)
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
