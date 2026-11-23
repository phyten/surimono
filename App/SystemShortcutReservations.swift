import AppKit
import Carbon.HIToolbox
import SurimonoCore

struct SystemShortcutReservations {
    static func read() -> [ShortcutSystemReservation]? {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr, let values else { return nil }
        guard let entries = values.takeRetainedValue() as? [[String: Any]] else { return nil }
        var result: [ShortcutSystemReservation] = []
        for entry in entries {
            guard let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool else { return nil }
            guard enabled else { continue }
            guard let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                let key = UInt16(exactly: code.uint32Value)
            else { return nil }
            result.append(
                .init(combination: .init(key: .macVirtualKey(key), modifiers: .carbon(modifiers.uint32Value))))
        }
        return result
    }
}

extension ShortcutModifiers {
    var carbon: UInt32 {
        [(Self.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
            .reduce(0) { $0 | (contains($1.0) ? UInt32($1.1) : 0) }
    }

    var symbols: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }.map(\.1).joined()
    }
}

extension KeyCombo {
    init?(_ combination: ShortcutCombination) {
        guard case .macVirtualKey(let code) = combination.key else { return nil }
        self.init(keyCode: UInt32(code), modifiers: combination.modifiers.carbon)
    }
}

struct ShortcutKeyboardLayout: Equatable {
    let projection: [ShortcutProjection]
    let names: [UInt16: String]
    let available: Bool

    static let special: [UInt16: ShortcutNamedKey] = [
        36: .return, 48: .tab, 49: .space, 51: .deleteBackward, 53: .escape, 76: .enter, 117: .deleteForward,
        123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6, 98: .f7,
        100: .f8, 101: .f9, 109: .f10, 103: .f11, 111: .f12, 105: .f13,
        107: .f14, 113: .f15, 106: .f16, 64: .f17, 79: .f18, 80: .f19, 90: .f20,
    ]

    // Both spellings are needed: Shift-3 and the produced # must reserve the same physical chord.
    static func project(translate: (UInt16, ShortcutModifiers) -> String?) -> Self {
        var projection: [ShortcutProjection] = []
        var names: [UInt16: String] = [:]
        for code: UInt16 in 0..<128 where ShortcutKey.macVirtualKey(code).isSupported {
            if let named = special[code] {
                names[code] = symbol(named)
            } else if let base = translate(code, []) {
                names[code] = base.uppercased()
            }
            for raw: UInt8 in 0..<16 {
                let flags = ShortcutModifiers(rawValue: raw)
                let physical = ShortcutCombination(key: .macVirtualKey(code), modifiers: flags)
                if let named = special[code] {
                    projection.append(.init(logical: .init(key: .named(named), modifiers: flags), physical: physical))
                    continue
                }
                // Command can change the base layout (for example Dvorak-QWERTY Command).
                for translatedFlags in [flags.intersection(.command), flags.subtracting(.control)] {
                    guard let text = translate(code, translatedFlags),
                        let logical = try? ShortcutCombination(key: .character(text), modifiers: flags).normalized()
                    else { continue }
                    // Normalizing punctuation drops Shift. Only the produced spelling may do that;
                    // keep the base spelling when it still carries Shift (for example Shift-3).
                    if flags.contains(.shift), !translatedFlags.contains(.shift), !logical.modifiers.contains(.shift) {
                        continue
                    }
                    projection.append(.init(logical: logical, physical: physical))
                }
            }
        }
        return Self(projection: projection, names: names, available: true)
    }

    // TIS returns the current data on every refresh. Equal layout bytes and keyboard type produce the same table.
    private static var cachedLayout: (data: Data, keyboardType: UInt32, layout: Self)?

    static func current() -> Self {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return Self(projection: [], names: [:], available: false)
        }
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return Self(projection: [], names: [:], available: false)
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return Self(projection: [], names: [:], available: false) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        let layoutData = data as Data
        if let cachedLayout, cachedLayout.keyboardType == keyboardType, cachedLayout.data == layoutData {
            return cachedLayout.layout
        }
        let result = project { code, flags in
            var deadKey: UInt32 = 0
            var count = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), (flags.carbon >> 8) & 0xFF,
                keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKey, characters.count, &count, &characters)
            guard status == noErr, count > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: count)
        }
        cachedLayout = (layoutData, keyboardType, result)
        return result
    }

    func display(_ combination: ShortcutCombination) -> String {
        let name: String
        switch combination.key {
        case .character(let character): name = character.uppercased()
        case .named(let key): name = Self.symbol(key)
        case .macVirtualKey(let code): name = names[code] ?? "#\(code)"
        }
        return combination.modifiers.symbols + name
    }

    static func symbol(_ key: ShortcutNamedKey) -> String {
        switch key {
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .space: "␣"
        case .deleteBackward: "⌫"
        case .deleteForward: "⌦"
        case .escape: "⎋"
        case .tab: "⇥"
        case .return: "↩"
        case .enter: "⌤"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        default: key.rawValue.uppercased()
        }
    }
}

extension ShortcutModifiers {
    private static let spokenNames: [(Self, String)] = [
        (.control, String(localized: "Control")), (.option, String(localized: "Option")),
        (.shift, String(localized: "Shift")), (.command, String(localized: "Command")),
    ]

    var spoken: String {
        Self.spokenNames.filter { contains($0.0) }.map(\.1).joined(separator: " ")
    }
}

extension ShortcutKeyboardLayout {
    func spoken(_ combination: ShortcutCombination) -> String {
        let key: ShortcutKey
        if case .macVirtualKey(let code) = combination.key, let special = Self.special[code] {
            key = .named(special)
        } else {
            key = combination.key
        }
        let name: String
        switch key {
        case .named(.leftArrow): name = String(localized: "Left Arrow")
        case .named(.rightArrow): name = String(localized: "Right Arrow")
        case .named(.upArrow): name = String(localized: "Up Arrow")
        case .named(.downArrow): name = String(localized: "Down Arrow")
        case .named(.space): name = String(localized: "Space")
        case .named(.deleteBackward): name = String(localized: "Delete")
        case .named(.deleteForward): name = String(localized: "Forward Delete")
        case .named(.escape): name = String(localized: "Escape")
        case .named(.tab): name = String(localized: "Tab")
        case .named(.return): name = String(localized: "Return")
        case .named(.enter): name = String(localized: "Enter")
        case .named(.home): name = String(localized: "Home")
        case .named(.end): name = String(localized: "End")
        case .named(.pageUp): name = String(localized: "Page Up")
        case .named(.pageDown): name = String(localized: "Page Down")
        default: name = display(.init(key: key))
        }
        return [combination.modifiers.spoken, name].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
