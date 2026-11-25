import AppKit
import Testing

@MainActor
enum TestWindowKeyboard {
    static func pressEscape(in window: NSWindow) throws {
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        // An inactive host may have no key window. Give the intended window's cancel shortcut the first chance,
        // then let its first responder handle an unclaimed Esc.
        // This checks one window only. It bypasses NSApplication's dispatch, so local event monitors, the choice
        // of the key window and menu key equivalents are not covered here.
        if !window.performKeyEquivalent(with: escape) {
            window.sendEvent(escape)
        }
    }
}
