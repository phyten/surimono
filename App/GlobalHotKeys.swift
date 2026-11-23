import AppKit
import Carbon.HIToolbox
import Observation
import SurimonoCore
import SwiftUI

struct KeyCombo: Codable, Hashable, Sendable {
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

@MainActor
@Observable
final class GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case open = 1
        case printScreen = 2

        var operation: ShortcutOperationID {
            self == .open ? .globalClipboardOpen : .globalClipboardPrintScreen
        }
    }

    enum RegistrationError: Error { case unavailable }
    static let shared = GlobalHotKeys()
    private static let signature: UInt32 = 0x5355_5249
    private struct Registration {
        let id: UInt32
        let release: () -> Void
    }
    private var registrations: [KeyCombo: Registration] = [:]
    private(set) var assignments: [KeyCombo: Action] = [:]
    private var nextID: UInt32 = 10
    private var handler: EventHandlerRef?
    private var recording = false
    var isRecording: Bool { recording }
    private var transacting = false
    private var handlerFailed = false
    private(set) var failed: Set<Action> = []
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

    func start() {
        stop()
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
    }

    func stop() {
        for entry in registrations.values { entry.release() }
        registrations.removeAll()
        assignments.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func handle(_ id: UInt32) {
        guard !recording, !transacting,
            let combo = registrations.first(where: { $0.value.id == id })?.key,
            let action = assignments[combo]
        else { return }
        activate()
        openClipboard(action == .printScreen)
    }

    func isRegistered(_ action: Action) -> Bool {
        assignments.contains { $0.value == action && registrations[$0.key] != nil }
    }

    // Registration IDs belong to combinations, so a transfer changes routing without re-registering a held key.
    func apply(_ desired: [KeyCombo: Action], commit: () throws -> Void = {}) throws {
        transacting = true
        defer { transacting = false }
        var acquired: [KeyCombo: Registration] = [:]
        do {
            for (combo, _) in desired where registrations[combo] == nil {
                guard !handlerFailed, !recording, let release = register(combo, nextID) else {
                    throw RegistrationError.unavailable
                }
                acquired[combo] = Registration(id: nextID, release: release)
                nextID += 1
            }
            try commit()
        } catch {
            for entry in acquired.values { entry.release() }
            throw error
        }
        let obsolete = registrations.filter { desired[$0.key] == nil }
        registrations.merge(acquired) { _, new in new }
        assignments = desired
        for (combo, entry) in obsolete {
            registrations.removeValue(forKey: combo)
            entry.release()
        }
        failed.removeAll()
    }

    // Saved assignments stay saved when another app prevents registration at launch or after recording.
    func synchronize(_ desired: [KeyCombo: Action]) {
        transacting = true
        defer { transacting = false }
        for (combo, entry) in registrations where desired[combo] == nil {
            entry.release()
            registrations.removeValue(forKey: combo)
        }
        if assignments != desired { assignments = desired }
        var failures: Set<Action> = []
        for (combo, action) in desired where !recording && registrations[combo] == nil {
            if !handlerFailed, let release = register(combo, nextID) {
                registrations[combo] = Registration(id: nextID, release: release)
                nextID += 1
            } else {
                failures.insert(action)
            }
        }
        if failed != failures { failed = failures }
    }

    func beginRecording() {
        recording = true
        for entry in registrations.values { entry.release() }
        registrations.removeAll()
    }

    func endRecording() {
        recording = false
        synchronize(assignments)
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

extension KeyCombo {
    func recordedShortcutCombination() throws -> ShortcutCombination {
        guard let code = UInt16(exactly: keyCode) else { throw ShortcutModelError.invalidKey }
        return try ShortcutCombination(key: .macVirtualKey(code), modifiers: .carbon(modifiers)).normalized()
    }

    func shortcutCombination() throws -> ShortcutCombination {
        guard isValid, let code = UInt16(exactly: keyCode) else { throw ShortcutModelError.invalidKey }
        var flags: ShortcutModifiers = []
        for (carbon, flag) in [
            (controlKey, ShortcutModifiers.control), (optionKey, .option),
            (shiftKey, .shift), (cmdKey, .command),
        ] where modifiers & UInt32(carbon) != 0 {
            flags.insert(flag)
        }
        return try ShortcutCombination(key: .macVirtualKey(code), modifiers: flags).normalized()
    }
}

struct LegacyShortcutMigration {
    static func evaluate(defaults: UserDefaults, environment: ShortcutValidationContext) -> ShortcutConfiguration {
        let sources: [(ShortcutOperationID, String)] = [
            (.globalClipboardOpen, "openClipboardShortcut"),
            (.globalClipboardPrintScreen, "printClipboardShortcut"),
        ]
        var overrides: [ShortcutOperationID: [ShortcutCombination]] = [:]
        var invalid: [ShortcutInactiveMigration] = []
        var rawValues: [ShortcutOperationID: Data] = [:]
        for (operation, key) in sources {
            guard defaults.object(forKey: key) != nil else { continue }
            let raw = defaults.data(forKey: key)
            rawValues[operation] = raw
            guard let raw, let legacy = try? JSONDecoder().decode(KeyCombo.self, from: raw),
                let candidate = try? legacy.shortcutCombination()
            else {
                overrides[operation] = []
                invalid.append(
                    .init(operation: operation, legacyData: raw, candidate: nil, reasons: [.malformedLegacy]))
                continue
            }
            overrides[operation] = [candidate]
        }
        // Validate both candidates together, so a duplicate does not acquire an arbitrary winner.
        let candidates = ShortcutConfiguration(overrides: overrides)
        let validator = ShortcutValidator(environment: environment)
        for (operation, _) in sources {
            guard let candidate = candidates.keys(for: operation).first else { continue }
            var reasons = validator.issues(for: operation, combination: candidate).map(\.code)
            if !validator.conflicts(for: operation, keys: [candidate], in: candidates).isEmpty {
                reasons.append(.conflict)
            }
            if !reasons.isEmpty {
                overrides[operation] = []
                invalid.append(
                    .init(
                        operation: operation, legacyData: rawValues[operation], candidate: candidate,
                        reasons: reasons))
            }
        }
        return ShortcutConfiguration(overrides: overrides, inactiveMigration: invalid)
    }
}
