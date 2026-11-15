import AppKit
import SurimonoCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let combo: KeyCombo?
    var displayTitle: String? = nil
    let label: String
    let hotKeys: GlobalHotKeys
    let refuse: () -> Void
    let change: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.hotKeys = hotKeys
        button.combo = combo
        button.displayTitle = displayTitle
        button.isEnabled = isEnabled
        if !isEnabled { button.finish() }
        button.change = change
        button.refuse = refuse
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(
            String(localized: "Record Shortcut") + ". "
                + String(localized: "Press a key combination. Escape cancels; Tab moves focus; Delete clears."))
        button.toolTip = String(localized: "Record Shortcut")
        button.font = displayTitle == nil ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.refresh()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }

    static func candidate(_ event: NSEvent) throws -> KeyCombo? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if [51, 117].contains(event.keyCode), modifiers.isEmpty, !event.modifierFlags.contains(.function) {
            return nil
        }
        guard let characters = event.characters, !characters.isEmpty else { throw ShortcutModelError.invalidKey }
        if event.modifierFlags.contains(.function) {
            // AppKit marks ordinary arrows and F-keys as function keys too. Fn-modified letters and
            // navigation translations (such as Fn-Left becoming Home) must not silently lose Fn.
            guard let expected = intrinsicFunctionCharacter(event.keyCode),
                event.charactersIgnoringModifiers == expected
            else { throw ShortcutModelError.invalidKey }
        }
        if [51, 117].contains(event.keyCode), modifiers.isEmpty { return nil }
        let combo = KeyCombo(event: event)
        _ = try combo.recordedShortcutCombination()
        return combo
    }

    private static func intrinsicFunctionCharacter(_ code: UInt16) -> String? {
        guard let key = ShortcutKeyboardLayout.special[code] else { return nil }
        let scalar: UInt32
        switch key {
        case .upArrow: scalar = 0xF700
        case .downArrow: scalar = 0xF701
        case .leftArrow: scalar = 0xF702
        case .rightArrow: scalar = 0xF703
        case .deleteForward: scalar = 0xF728
        case .home: scalar = 0xF729
        case .end: scalar = 0xF72B
        case .pageUp: scalar = 0xF72C
        case .pageDown: scalar = 0xF72D
        default:
            guard key.rawValue.first == "f", let number = UInt32(key.rawValue.dropFirst()) else { return nil }
            scalar = 0xF703 + number
        }
        return UnicodeScalar(scalar).map { String($0) }
    }

    final class RecorderButton: NSButton {
        var hotKeys: GlobalHotKeys?
        var combo: KeyCombo?
        var displayTitle: String?
        var change: ((KeyCombo?) -> Void)?
        var refuse: (() -> Void)?
        private var recording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(record)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            finish()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            if let newWindow {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(cancelRecording), name: NSWindow.didResignKeyNotification,
                    object: newWindow)
            }
            super.viewWillMove(toWindow: newWindow)
        }
        @objc private func cancelRecording() { finish() }

        func refresh() {
            title =
                recording
                ? String(localized: "Type a shortcut")
                : displayTitle ?? combo?.display ?? String(localized: "Record Shortcut")
            setAccessibilityValue(title)
        }
        @objc private func record() {
            guard isEnabled, !recording, window?.makeFirstResponder(self) == true else { return }
            recording = true
            hotKeys?.beginRecording()
            refresh()
        }
        func finish() {
            guard recording else { return }
            recording = false
            hotKeys?.endRecording()
            refresh()
        }
        override func resignFirstResponder() -> Bool {
            finish()
            return super.resignFirstResponder()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                finish()
                return
            }
            if event.keyCode == 48 {
                finish()
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
                return
            }
            guard !event.isARepeat else { return }
            let value: KeyCombo?
            do { value = try ShortcutRecorder.candidate(event) } catch {
                finish()
                refuse?()
                return
            }
            // Resume before applying so failure leaves the previous shortcut active.
            finish()
            change?(value)
        }
    }
}
