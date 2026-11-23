import AppKit
import SurimonoCore
import SwiftUI

/// Leave the native responder in place after Escape or a completed recording until focus actually moves.
struct ShortcutRecordingControl: View {
    let title: String
    let displaysKeys: Bool
    let label: String
    let hotKeys: GlobalHotKeys
    let refuse: () -> Void
    let change: (KeyCombo?) -> Void
    @State private var editing = false

    var body: some View {
        if editing {
            ShortcutRecorder(
                displayTitle: title, displaysKeys: displaysKeys, label: label, hotKeys: hotKeys,
                refuse: refuse, change: change, leave: { editing = false })
        } else {
            Button {
                editing = true
            } label: {
                Text(verbatim: title)
                    .font(displaysKeys ? .system(size: 13, weight: .medium, design: .monospaced) : .system(size: 13))
            }
            .buttonStyle(.bordered)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                editing = true
                return .handled
            }
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityHint(Text(verbatim: ShortcutRecorder.recordingHelp))
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let displayTitle: String
    let displaysKeys: Bool
    let label: String
    let hotKeys: GlobalHotKeys
    let refuse: () -> Void
    let change: (KeyCombo?) -> Void
    let leave: () -> Void

    static let recordingHelp =
        String(localized: "Record Shortcut") + ". "
        + String(localized: "Press a key combination. Escape cancels; Tab moves focus; Delete clears.")

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        configure(button)
        if !isEnabled { button.endInteraction() }
    }

    private func configure(_ button: RecorderButton) {
        button.hotKeys = hotKeys
        button.displayTitle = displayTitle
        button.isEnabled = isEnabled
        button.change = change
        button.refuse = refuse
        button.leave = leave
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(Self.recordingHelp)
        button.toolTip = String(localized: "Record Shortcut")
        button.font = displaysKeys ? .monospacedSystemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
        button.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) {
        button.leave = nil
        button.finish()
    }

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
        var displayTitle: String?
        var change: ((KeyCombo?) -> Void)?
        var refuse: (() -> Void)?
        var leave: (() -> Void)?
        private var startsOnAttach = true
        private var recording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(record)
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, startsOnAttach else { return }
            startsOnAttach = false
            record()
            if !recording { endInteraction() }
        }

        @objc private func cancelRecording() { finish() }

        func endInteraction() {
            finish()
            guard let leave else { return }
            self.leave = nil
            // AppKit can move focus while SwiftUI is updating the hierarchy.
            Task { @MainActor in leave() }
        }

        func refresh() {
            title =
                recording
                ? String(localized: "Type a shortcut")
                : displayTitle ?? String(localized: "Record Shortcut")
            setAccessibilityValue(title)
        }
        @objc private func record() {
            guard acceptsFirstResponder, !recording, window?.makeFirstResponder(self) == true else { return }
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
            endInteraction()
            return super.resignFirstResponder()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else {
                if [36, 49, 76].contains(event.keyCode),
                    event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                {
                    performClick(nil)
                    return
                }
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
