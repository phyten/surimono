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
        DocumentEditMenu.hideItems(in: menu)
        #expect(edits.allSatisfy { $0.isHidden && !$0.allowsKeyEquivalentWhenHidden })
        #expect(!close.isHidden)
        #expect(!share.isHidden)
    }

    @Test("復帰の後ろに出るバージョンの小メニューも隠す")
    func hidesRevertSubmenu() {
        let menu = NSMenu()
        menu.addItem(item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))))
        let revertTo = item("Revert To", nil)
        revertTo.submenu = NSMenu()
        menu.addItem(revertTo)
        DocumentEditMenu.hideItems(in: menu)
        #expect(revertTo.isHidden)
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

    @Test("あとから足された項目や表示に戻された項目も、その場で隠す")
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
