import AppKit
import Testing

@testable import Surimono

@MainActor
struct KeyGuideTests {
    @Test("キーと操作の一覧は紙・ツールバー・検索・印刷・手の操作を19項目で案内する")
    func entries() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        #expect(
            KeyGuideEntry.allCases == [
                .menu, .alwaysShowToolbar, .viewOptions, .selectText, .alternateDrag, .pageEdge, .doubleClick, .pinch,
                .find, .findStep, .goToPage, .reload,
                .print, .systemPrint, .printLayouts, .escape, .moveSelection, .removeFromList, .showList,
            ])
        #expect(KeyGuideEntry.find.trigger(controller: f.controller) == "⌘F")
        #expect(KeyGuideEntry.findStep.trigger(controller: f.controller) == "⌘G / ⇧⌘G")
        #expect(KeyGuideEntry.goToPage.trigger(controller: f.controller) == "⌥⌘G")
        #expect(KeyGuideEntry.reload.trigger(controller: f.controller) == "⌘R")
        #expect(KeyGuideEntry.menu.trigger(controller: f.controller) == "Tab / ⇧Tab / M / ⇧M")
        #expect(KeyGuideEntry.alwaysShowToolbar.trigger(controller: f.controller) == "⌥⌘T")
        #expect(KeyGuideEntry.viewOptions.trigger(controller: f.controller) == "V / ⇧V")
        #expect(KeyGuideEntry.selectText.trigger(controller: f.controller) == "T / ⇧T")
        #expect(KeyGuideEntry.print.trigger(controller: f.controller) == "⌘P")
        #expect(KeyGuideEntry.systemPrint.trigger(controller: f.controller) == "⌥⌘P")
        #expect(KeyGuideEntry.printLayouts.trigger(controller: f.controller) == "⌘1–⌘6")
        #expect(KeyGuideEntry.escape.trigger(controller: f.controller) == "Esc")
        #expect(KeyGuideEntry.moveSelection.trigger(controller: f.controller) == "⌥⌘↑ / ⌥⌘↓")
        #expect(KeyGuideEntry.removeFromList.trigger(controller: f.controller) == "⌫")
        #expect(KeyGuideEntry.showList.trigger(controller: f.controller) == "⌃⌘S")
    }

    @Test("紙のキー処理は一覧のTab・M・V・T・Escに対応する")
    func paperKeys() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        for (characters, keyCode, expected) in [
            ("\t", UInt16(48), KeyGuideEntry.menu), ("m", 46, .menu), ("M", 46, .menu),
            ("v", 9, .viewOptions), ("t", 17, .selectText), ("\u{1b}", 53, .escape),
        ] {
            let event = try event(characters, keyCode: keyCode)
            #expect(KeyGuideEntry.paperAction(for: event, controller: f.controller) == expected)
            #expect(KeyGuideEntry.allCases.contains(expected))
        }
        #expect(KeyGuideEntry.paperAction(for: try event("x", keyCode: 7), controller: f.controller) == nil)
    }

    @Test("紙の単独キーはCommand・Option・Controlを奪わずShiftは許す")
    func modifiers() throws {
        let f = try ShortcutSurfaceFixture()
        defer { f.close() }
        for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
            for (characters, code) in [("m", UInt16(46)), ("v", 9), ("t", 17), ("\t", 48), ("\u{1b}", 53)] {
                #expect(
                    KeyGuideEntry.paperAction(
                        for: try event(characters, keyCode: code, flags: flags), controller: f.controller) == nil)
            }
        }
        #expect(
            KeyGuideEntry.paperAction(for: try event("M", keyCode: 46, flags: .shift), controller: f.controller)
                == .menu)
    }

    private func event(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
    }
}
