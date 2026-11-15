import Foundation

public struct ShortcutInactiveMigration: Equatable, Sendable, Codable {
    public let operation: ShortcutOperationID
    public let legacyData: Data?
    public let candidate: ShortcutCombination?
    public let reasons: [ShortcutValidationIssue.Code]

    public init(
        operation: ShortcutOperationID, legacyData: Data?, candidate: ShortcutCombination?,
        reasons: [ShortcutValidationIssue.Code]
    ) {
        self.operation = operation
        self.legacyData = legacyData
        self.candidate = candidate
        self.reasons = reasons
    }
}

public struct ShortcutConfiguration: Equatable, Sendable, Codable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let overrides: [ShortcutOperationID: [ShortcutCombination]]
    public let inactiveMigration: [ShortcutInactiveMigration]

    public init(
        overrides: [ShortcutOperationID: [ShortcutCombination]] = [:],
        inactiveMigration: [ShortcutInactiveMigration] = []
    ) {
        schemaVersion = Self.currentVersion
        self.overrides = overrides
        self.inactiveMigration = inactiveMigration
    }

    public func keys(for operation: ShortcutOperationID) -> [ShortcutCombination] {
        overrides[operation] ?? ShortcutDefaults.keys(for: operation)
    }

    public func bindings(for operation: ShortcutOperationID) -> [ShortcutBinding] {
        let metadata = ShortcutOperation.operation(operation)
        return keys(for: operation).map { metadata.binding(for: $0) }
    }

    public func replacing(_ operation: ShortcutOperationID, with keys: [ShortcutCombination]?) -> Self {
        var changed = overrides
        changed[operation] = keys
        return Self(overrides: changed, inactiveMigration: inactiveMigration.filter { $0.operation != operation })
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, overrides, inactiveMigration }
    private struct Entry: Codable {
        let operation: String
        let keys: [ShortcutCombination]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentVersion else { throw ShortcutModelError.unsupportedVersion(version) }
        let entries = try container.decode([Entry].self, forKey: .overrides)
        guard entries.count <= 2_048 else { throw ShortcutModelError.tooManyEntries }
        var overrides: [ShortcutOperationID: [ShortcutCombination]] = [:]
        for entry in entries {
            guard let operation = ShortcutOperationID(rawValue: entry.operation) else {
                // A local store is not an import: discarding a future entry would destroy the reader's data.
                throw ShortcutModelError.unknownOperation(entry.operation)
            }
            guard overrides[operation] == nil else { throw ShortcutModelError.duplicateOperation(entry.operation) }
            overrides[operation] = try Self.normalizedKeys(entry.keys)
        }
        let inactive = try container.decode([ShortcutInactiveMigration].self, forKey: .inactiveMigration)
        guard inactive.count <= 2, Set(inactive.map(\.operation)).count == inactive.count,
            inactive.allSatisfy({
                ShortcutOperation.operation($0.operation).isGlobal && !$0.reasons.isEmpty
                    && (overrides[$0.operation] ?? []).isEmpty
            })
        else {
            throw ShortcutModelError.malformedStore
        }
        self.init(overrides: overrides, inactiveMigration: inactive)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        let entries = try ShortcutOperationID.allCases.compactMap { operation -> Entry? in
            guard let keys = overrides[operation] else { return nil }
            return Entry(operation: operation.rawValue, keys: try Self.normalizedKeys(keys))
        }
        try container.encode(entries, forKey: .overrides)
        try container.encode(inactiveMigration, forKey: .inactiveMigration)
    }

    public static func normalizedKeys(_ keys: [ShortcutCombination]) throws -> [ShortcutCombination] {
        guard keys.count <= 8 else { throw ShortcutModelError.tooManyBindings }
        var result: [ShortcutCombination] = []
        for key in keys {
            let normalized = try key.normalized()
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }
}

public enum ShortcutStore: Sendable {
    public static let preferencesKey = "keyboardShortcuts.v1"
    public static let maximumBytes = 1_048_576

    public static func decode(_ data: Data) throws -> ShortcutConfiguration {
        guard data.count <= maximumBytes else { throw ShortcutModelError.dataTooLarge }
        do {
            try checkShape(data)
            let configuration = try JSONDecoder().decode(ShortcutConfiguration.self, from: data)
            let validator = ShortcutValidator(environment: .init())
            // Physical keys need the platform's projection; loading cannot invent a keyboard layout.
            let invalid = validator.issues(in: configuration).filter { $0.code != .layoutProjectionUnavailable }
            guard invalid.isEmpty else { throw ShortcutModelError.validation(invalid) }
            let conflicts = validator.conflicts(in: configuration)
            guard conflicts.isEmpty else { throw ShortcutModelError.conflicts(conflicts) }
            return configuration
        } catch let error as ShortcutModelError {
            throw error
        } catch {
            throw ShortcutModelError.malformedStore
        }
    }

    private static func checkShape(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
            Set(root.keys) == ["schemaVersion", "overrides", "inactiveMigration"],
            let overrides = root["overrides"] as? [[String: Any]],
            let inactive = root["inactiveMigration"] as? [[String: Any]]
        else {
            throw ShortcutModelError.malformedStore
        }
        for entry in overrides {
            guard Set(entry.keys) == ["operation", "keys"], let keys = entry["keys"] as? [[String: Any]] else {
                throw ShortcutModelError.malformedStore
            }
            for key in keys { try checkCombination(key) }
        }
        for record in inactive {
            guard Set(record.keys).isSubset(of: ["operation", "legacyData", "candidate", "reasons"]) else {
                throw ShortcutModelError.malformedStore
            }
            if let candidate = record["candidate"] as? [String: Any] { try checkCombination(candidate) }
        }
    }

    static func checkCombination(_ combination: [String: Any]) throws {
        guard Set(combination.keys) == ["key", "modifiers"], let key = combination["key"] as? [String: Any],
            let kind = key["kind"] as? String
        else { throw ShortcutModelError.malformedStore }
        let expected: Set<String> = kind == "macVirtualKey" ? ["kind", "code"] : ["kind", "value"]
        guard Set(key.keys) == expected else { throw ShortcutModelError.malformedStore }
    }

    public static func encode(_ configuration: ShortcutConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        guard data.count <= maximumBytes else { throw ShortcutModelError.dataTooLarge }
        _ = try decode(data)
        return data
    }
}
