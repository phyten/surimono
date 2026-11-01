import AppKit
import Testing

@testable import Surimono

@MainActor
struct KeyGuideTests {
    @Test("キーと操作の一覧は紙・印刷・手の操作を10項目で案内する")
    func entries() {
        #expect(
            KeyGuideEntry.allCases == [
                .menu, .viewOptions, .selectText, .alternateDrag, .pageEdge, .doubleClick,
                .print, .systemPrint, .printLayouts, .escape,
            ])
        #expect(KeyGuideEntry.menu.trigger == "Tab / M")
        #expect(KeyGuideEntry.viewOptions.trigger == "V")
        #expect(KeyGuideEntry.selectText.trigger == "T")
        #expect(KeyGuideEntry.print.trigger == "⌘P")
        #expect(KeyGuideEntry.systemPrint.trigger == "⌥⌘P")
        #expect(KeyGuideEntry.printLayouts.trigger == "⌘1–⌘6")
        #expect(KeyGuideEntry.escape.trigger == "Esc")
    }

    @Test("紙のキー処理は一覧のTab・M・V・T・Escに対応する")
    func paperKeys() throws {
        for (characters, keyCode, expected) in [
            ("\t", UInt16(48), KeyGuideEntry.menu), ("m", 46, .menu), ("M", 46, .menu),
            ("v", 9, .viewOptions), ("t", 17, .selectText), ("\u{1b}", 53, .escape),
        ] {
            let event = try event(characters, keyCode: keyCode)
            #expect(KeyGuideEntry.paperAction(for: event) == expected)
            #expect(KeyGuideEntry.allCases.contains(expected))
        }
        #expect(KeyGuideEntry.paperAction(for: try event("x", keyCode: 7)) == nil)
    }

    @Test("紙の単独キーはCommand・Option・Controlを奪わずShiftは許す")
    func modifiers() throws {
        for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
            for (characters, code) in [("m", UInt16(46)), ("v", 9), ("t", 17), ("\t", 48), ("\u{1b}", 53)] {
                #expect(KeyGuideEntry.paperAction(for: try event(characters, keyCode: code, flags: flags)) == nil)
            }
        }
        #expect(KeyGuideEntry.paperAction(for: try event("M", keyCode: 46, flags: .shift)) == .menu)
    }

    private func event(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
    }
}
