import Foundation

public struct ShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let command = Self(rawValue: 8)
    public static let all: Self = [.control, .option, .shift, .command]
    private static let names: [(String, Self)] = [
        ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
    ]

    public init(from decoder: any Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var result: Self = []
        for name in names {
            guard let value = Self.names.first(where: { $0.0 == name })?.1, !result.contains(value) else {
                throw ShortcutModelError.invalidModifiers
            }
            result.insert(value)
        }
        self = result
    }

    public func encode(to encoder: any Encoder) throws {
        guard subtracting(.all).isEmpty else { throw ShortcutModelError.invalidModifiers }
        var container = encoder.singleValueContainer()
        try container.encode(Self.names.filter { contains($0.1) }.map(\.0))
    }
}

public enum ShortcutNamedKey: String, CaseIterable, Codable, Sendable {
    case leftArrow, rightArrow, upArrow, downArrow, space, deleteBackward, deleteForward
    case escape, tab, `return`, enter, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    public var isArrow: Bool { [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(self) }
}

public enum ShortcutKey: Hashable, Sendable, Codable {
    case character(String)
    case named(ShortcutNamedKey)
    case macVirtualKey(UInt16)

    private enum CodingKeys: String, CodingKey { case kind, value, code }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "character": self = .character(try container.decode(String.self, forKey: .value))
        case "named": self = .named(try container.decode(ShortcutNamedKey.self, forKey: .value))
        case "macVirtualKey": self = .macVirtualKey(try container.decode(UInt16.self, forKey: .code))
        default: throw ShortcutModelError.invalidKey
        }
        guard isSupported else { throw ShortcutModelError.invalidKey }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isSupported else { throw ShortcutModelError.invalidKey }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .character(let value):
            try container.encode("character", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .named(let value):
            try container.encode("named", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .macVirtualKey(let code):
            try container.encode("macVirtualKey", forKey: .kind)
            try container.encode(code, forKey: .code)
        }
    }

    public var isSupported: Bool {
        switch self {
        case .character(let value):
            return value.count == 1
                && !value.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
                        || (0xF700...0xF8FF).contains($0.value)
                } && value.unicodeScalars.contains { !CharacterSet.nonBaseCharacters.contains($0) }
        case .named: return true
        case .macVirtualKey(let code):
            // Only ordinary ANSI, ISO, JIS, keypad and function keys; not modifiers, media or power keys.
            return (0...51).contains(code) || [53, 64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81].contains(code)
                || (82...89).contains(code) || (90...101).contains(code)
                || [
                    102, 103, 104, 105, 106, 107, 109, 111, 113, 114, 115, 116, 117, 118, 119, 120, 121,
                    122, 123, 124, 125, 126,
                ].contains(code)
        }
    }
}

public struct ShortcutCombination: Hashable, Sendable, Codable {
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers

    public init(key: ShortcutKey, modifiers: ShortcutModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public func normalized() throws -> Self {
        guard key.isSupported else { throw ShortcutModelError.invalidKey }
        guard modifiers.subtracting(.all).isEmpty else { throw ShortcutModelError.invalidModifiers }
        guard case .character(let value) = key else { return self }
        let character = value.precomposedStringWithCanonicalMapping.lowercased()
        guard character.count == 1 else { throw ShortcutModelError.invalidKey }
        let isLetter = character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return Self(key: .character(character), modifiers: isLetter ? modifiers : modifiers.subtracting(.shift))
    }
}

public enum ShortcutModelError: Error, Equatable, Sendable {
    case invalidKey, invalidModifiers, malformedStore
    case unsupportedVersion(Int)
    case unknownOperation(String)
    case duplicateOperation(String)
    case tooManyBindings, tooManyEntries, dataTooLarge
    case validation([ShortcutValidationIssue])
    case conflicts([ShortcutConflict])
}

public struct ShortcutInput: Sendable {
    public enum AuxiliaryModifier: Sendable { case capsLock, numericPad, function }
    public let combination: ShortcutCombination?
    public let auxiliaryModifiers: Set<AuxiliaryModifier>
    public let isDeadKey: Bool
    public let strokeCount: Int

    public init(
        combination: ShortcutCombination?, auxiliaryModifiers: Set<AuxiliaryModifier> = [],
        isDeadKey: Bool = false, strokeCount: Int = 1
    ) {
        self.combination = combination
        self.auxiliaryModifiers = auxiliaryModifiers
        self.isDeadKey = isDeadKey
        self.strokeCount = strokeCount
    }

    public func normalized() throws -> ShortcutCombination {
        guard let combination, !isDeadKey, strokeCount == 1, !auxiliaryModifiers.contains(.function) else {
            throw ShortcutModelError.invalidKey
        }
        return try combination.normalized()
    }
}
