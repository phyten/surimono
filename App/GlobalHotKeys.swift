import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

struct KeyCombo: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.allowedModifiers == 0
            && modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
            && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    func isValid(excluding other: KeyCombo?) -> Bool { isValid && self != other }

    func display(key: String) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    var display: String { display(key: Self.keyName(keyCode)) }

    private static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        if let name = special[code] { return name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKey: UInt32 = 0
                var count = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, characters.count, &count, &characters)
                if status == noErr, count > 0 {
                    return String(utf16CodeUnits: characters, count: count).uppercased()
                }
            }
        }
        return "#\(code)"
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = [
            (NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey),
        ].reduce(0) { $0 | (event.modifierFlags.contains($1.0) ? UInt32($1.1) : 0) }
    }
}

@Observable
final class GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case open = 1
        case printScreen = 2

        var title: String {
            switch self {
            case .open: String(localized: "Open from Clipboard")
            case .printScreen: String(localized: "Open Clipboard on the Print Screen")
            }
        }
    }

    static let shared = GlobalHotKeys()
    private static let signature: UInt32 = 0x5355_5249
    private var preferences: AppPreferences?
    private var releases: [Action: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private(set) var errors: [Action: String] = [:]
    private var recording = false
    private var handlerFailed = false
    private let register: (KeyCombo, UInt32) -> (() -> Void)?
    private let activate: () -> Void
    private let openClipboard: (Bool) -> Void

    init(
        register: @escaping (KeyCombo, UInt32) -> (() -> Void)? = { GlobalHotKeys.registerCarbon($0, $1) },
        activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        openClipboard: @escaping (Bool) -> Void = { ClipboardWindows.shared.open(printing: $0) }
    ) {
        self.register = register
        self.activate = activate
        self.openClipboard = openClipboard
    }

    func start(preferences: AppPreferences) {
        stop()
        self.preferences = preferences
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                guard let event,
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == 0x5355_5249
                else { return OSStatus(eventNotHandledErr) }
                let actionID = id.id
                Task { @MainActor in GlobalHotKeys.shared.handle(actionID) }
                return noErr
            }, 1, &event, nil, &handler)
        handlerFailed = status != noErr
        if status == noErr {
            restore()
        } else {
            for action in Action.allCases {
                errors[action] = String(localized: "Could not register this shortcut. Try another combination.")
            }
        }
    }

    func stop() {
        for release in releases.values { release() }
        releases.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func combo(for action: Action) -> KeyCombo? {
        action == .open ? preferences?.openClipboardShortcut : preferences?.printClipboardShortcut
    }

    func handle(_ id: UInt32) {
        guard !recording, let action = Action(rawValue: id) else { return }
        activate()
        openClipboard(action == .printScreen)
    }

    func set(_ combo: KeyCombo?, for action: Action) {
        guard let preferences else { return }
        let other = self.combo(for: action == .open ? .printScreen : .open)
        if let combo, !combo.isValid(excluding: other) {
            errors[action] = String(
                localized: "Use Command, Option, or Control and a different shortcut for each action.")
            return
        }
        if combo == self.combo(for: action), releases[action] != nil {
            errors[action] = nil
            return
        }
        // Keep the old registration until the replacement is known to work.
        var release: (() -> Void)?
        if let combo {
            guard !handlerFailed else {
                errors[action] = String(localized: "Could not register this shortcut. Try another combination.")
                return
            }
            guard let registered = register(combo, action.rawValue) else {
                errors[action] = String(localized: "Could not register this shortcut. Try another combination.")
                return
            }
            release = registered
        }
        releases.removeValue(forKey: action)?()
        releases[action] = release
        if action == .open {
            preferences.openClipboardShortcut = combo
        } else {
            preferences.printClipboardShortcut = combo
        }
        errors[action] = nil
    }

    func beginRecording() {
        recording = true
        for release in releases.values { release() }
        releases.removeAll()
    }

    func endRecording() {
        recording = false
        restore()
    }

    /// Also supports tests without installing a process-wide Carbon handler.
    func restore(preferences: AppPreferences? = nil) {
        if let preferences { self.preferences = preferences }
        for action in Action.allCases where releases[action] == nil {
            if let combo = combo(for: action) { set(combo, for: action) }
        }
    }

    private static func registerCarbon(_ combo: KeyCombo, _ id: UInt32) -> (() -> Void)? {
        var reference: EventHotKeyRef?
        guard
            RegisterEventHotKey(
                combo.keyCode, combo.modifiers, EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference) == noErr, let reference
        else { return nil }
        return { UnregisterEventHotKey(reference) }
    }
}

struct GlobalShortcutSettings: View {
    private let hotKeys = GlobalHotKeys.shared

    var body: some View {
        Section("Global Shortcuts") {
            ForEach(GlobalHotKeys.Action.allCases, id: \.rawValue) { action in
                VStack(alignment: .leading) {
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(combo: hotKeys.combo(for: action), label: action.title) {
                            hotKeys.set($0, for: action)
                        }
                        .frame(width: 160, height: 26)
                        if hotKeys.combo(for: action) != nil {
                            Button {
                                hotKeys.set(nil, for: action)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear Shortcut") + Text(": ") + Text(action.title))
                        }
                    }
                    if let error = hotKeys.errors[action] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text("These work while Surimono is running, even when another app is in front.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let label: String
    let change: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.combo = combo
        button.change = change
        button.setAccessibilityLabel(label)
        button.refresh()
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }

    final class RecorderButton: NSButton {
        var combo: KeyCombo?
        var change: ((KeyCombo?) -> Void)?
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
                ? String(localized: "Type a shortcut") : combo?.display ?? String(localized: "Record Shortcut")
            setAccessibilityValue(title)
        }
        @objc private func record() {
            guard !recording, window?.makeFirstResponder(self) == true else { return }
            recording = true
            GlobalHotKeys.shared.beginRecording()
            refresh()
        }
        func finish() {
            guard recording else { return }
            recording = false
            GlobalHotKeys.shared.endRecording()
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
            let value: KeyCombo? = [51, 117].contains(event.keyCode) ? nil : KeyCombo(event: event)
            // Resume before applying so failure leaves the previous shortcut active.
            finish()
            change?(value)
        }
    }
}
