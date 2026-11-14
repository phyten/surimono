import AppKit
import Carbon.HIToolbox
import Testing

@testable import Surimono

@MainActor
struct GlobalHotKeysTests {
    @Test("修飾キーなしとShiftだけと未知の修飾キーは登録できない")
    func validation() {
        for modifiers: UInt32 in [0, UInt32(shiftKey), UInt32(cmdKey) | 1] {
            #expect(!KeyCombo(keyCode: 9, modifiers: modifiers).isValid)
        }
        #expect(KeyCombo(keyCode: 9, modifiers: UInt32(controlKey | optionKey | cmdKey)).isValid)
        #expect(!KeyCombo(keyCode: 55, modifiers: UInt32(cmdKey)).isValid)
        #expect(!KeyCombo(keyCode: 128, modifiers: UInt32(cmdKey)).isValid)
    }

    @Test("同じ組は二つの操作に割り当てられない")
    func duplicate() {
        let combo = KeyCombo(keyCode: 9, modifiers: UInt32(cmdKey))
        #expect(!combo.isValid(excluding: combo))
        #expect(combo.isValid(excluding: KeyCombo(keyCode: 8, modifiers: UInt32(cmdKey))))
    }

    @Test("修飾キーは標準の順に表示し特殊キーにも名前を付ける")
    func display() {
        #expect(KeyCombo(keyCode: 9, modifiers: UInt32(controlKey | optionKey | cmdKey)).display(key: "V") == "⌃⌥⌘V")
        #expect(KeyCombo(keyCode: 0, modifiers: UInt32(shiftKey | cmdKey)).display(key: "Q") == "⇧⌘Q")
        #expect(KeyCombo(keyCode: 123, modifiers: UInt32(cmdKey)).display == "⌘←")
    }

    @Test("未設定で始まり二つの組を保存して読み戻し削除できる")
    func persistence() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.openClipboardShortcut == nil)
        #expect(preferences.printClipboardShortcut == nil)
        let combo = KeyCombo(keyCode: 9, modifiers: UInt32(controlKey | cmdKey))
        #expect(try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo)) == combo)
        preferences.openClipboardShortcut = combo
        preferences.printClipboardShortcut = KeyCombo(keyCode: 8, modifiers: UInt32(optionKey))
        let restored = AppPreferences(defaults: suite.defaults)
        #expect(restored.openClipboardShortcut == combo)
        #expect(restored.printClipboardShortcut == KeyCombo(keyCode: 8, modifiers: UInt32(optionKey)))
        restored.openClipboardShortcut = nil
        #expect(AppPreferences(defaults: suite.defaults).openClipboardShortcut == nil)
    }

    @Test("登録失敗では以前の保存値と登録を残す")
    func registrationFailure() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let original = KeyCombo(keyCode: 9, modifiers: UInt32(cmdKey))
        var released = 0
        let keys = GlobalHotKeys(register: { combo, _ in
            combo == original ? { released += 1 } : nil
        })
        defer { keys.stop() }
        keys.restore(preferences: preferences)
        keys.set(original, for: .open)
        keys.set(KeyCombo(keyCode: 8, modifiers: UInt32(cmdKey)), for: .open)
        #expect(preferences.openClipboardShortcut == original)
        #expect(keys.errors[.open] != nil)
        #expect(released == 0)
        keys.set(original, for: .printScreen)
        #expect(preferences.printClipboardShortcut == nil)
        keys.set(nil, for: .open)
        #expect(released == 1)
        #expect(preferences.openClipboardShortcut == nil)
    }

    @Test("各ホットキーは前面に出してから印刷指定をクリップボードの窓口へ渡す")
    func dispatch() {
        var calls: [String] = []
        let keys = GlobalHotKeys(
            activate: { calls.append("activate") },
            openClipboard: { calls.append($0 ? "print" : "view") })
        keys.handle(1)
        keys.handle(2)
        keys.handle(99)
        #expect(calls == ["activate", "view", "activate", "print"])
        keys.beginRecording()
        keys.handle(1)
        #expect(calls.count == 4)
        keys.endRecording()
    }

    @Test("クリップボードのファイル経路も印刷指定を保つ")
    func clipboardFiles() {
        let board = NSPasteboard(name: .init("SurimonoTests.hotkeys.\(UUID())"))
        defer { board.releaseGlobally() }
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/shortcut-test.md")])
        var printingValues: [Bool] = []
        let windows = ClipboardWindows(
            openFiles: { _, _, printing in printingValues.append(printing) },
            warn: { _ in Issue.record("警告しない") }, closeWelcome: {})
        let keys = GlobalHotKeys(
            activate: {},
            openClipboard: {
                windows.open(from: board, window: nil, printing: $0)
            })
        keys.handle(1)
        keys.handle(2)
        #expect(printingValues == [false, true])
    }

    @Test("空のクリップボードは窓がなくても通知する")
    func emptyClipboard() {
        let board = NSPasteboard(name: .init("SurimonoTests.hotkeys.\(UUID())"))
        defer { board.releaseGlobally() }
        var warned = false
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("開かない") },
            warn: { window in
                warned = true
                #expect(window == nil)
            }, closeWelcome: {})
        windows.open(from: board, window: nil, printing: true)
        #expect(warned)
    }
}
