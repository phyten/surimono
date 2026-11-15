import Foundation

/// Portable overrides only: no migration records, machine reservations or external menu equivalents.
public struct ShortcutArchive: Equatable, Sendable {
    public static let format = "io.github.phyten.surimono.keyboard-shortcuts"
    public let bindings: [String: [ShortcutCombination]]

    public init(configuration: ShortcutConfiguration) {
        bindings = Dictionary(uniqueKeysWithValues: configuration.overrides.map { ($0.key.rawValue, $0.value) })
    }

    private init(bindings: [String: [ShortcutCombination]]) { self.bindings = bindings }

    private struct Document: Codable {
        let format: String
        let version: Int
        let bindings: [Entry]
    }

    private struct Entry: Codable {
        let operation: String
        let keys: [ShortcutCombination]
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ShortcutStore.maximumBytes else { throw ShortcutModelError.dataTooLarge }
        do {
            struct Header: Decodable {
                let format: String
                let version: Int
            }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.format == format else { throw ShortcutModelError.malformedStore }
            guard header.version == 1 else { throw ShortcutModelError.unsupportedVersion(header.version) }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.format == format else { throw ShortcutModelError.malformedStore }
            guard document.version == 1 else { throw ShortcutModelError.unsupportedVersion(document.version) }
            guard document.bindings.count <= 2_048 else { throw ShortcutModelError.tooManyEntries }
            // Reject extra fields and ambiguous key representations rather than silently losing them.
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == ["format", "version", "bindings"],
                let entries = root["bindings"] as? [[String: Any]]
            else { throw ShortcutModelError.malformedStore }
            for entry in entries {
                guard Set(entry.keys) == ["operation", "keys"], let keys = entry["keys"] as? [[String: Any]] else {
                    throw ShortcutModelError.malformedStore
                }
                for key in keys { try ShortcutStore.checkCombination(key) }
            }
            var bindings: [String: [ShortcutCombination]] = [:]
            for entry in document.bindings {
                guard bindings[entry.operation] == nil else {
                    throw ShortcutModelError.duplicateOperation(entry.operation)
                }
                bindings[entry.operation] = try ShortcutConfiguration.normalizedKeys(entry.keys)
            }
            return Self(bindings: bindings)
        } catch let error as ShortcutModelError {
            throw error
        } catch { throw ShortcutModelError.malformedStore }
    }

    public func encode() throws -> Data {
        let document = Document(
            format: Self.format, version: 1,
            bindings: try bindings.keys.sorted().map {
                Entry(operation: $0, keys: try ShortcutConfiguration.normalizedKeys(bindings[$0] ?? []))
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        _ = try Self.decode(data)
        return data
    }
}

/// A detached draft. Constructing, reviewing and discarding it have no persistence or registration effects.
public struct ShortcutImportReview: Equatable, Sendable {
    public let original: ShortcutConfiguration
    public private(set) var configuration: ShortcutConfiguration
    public let incoming: Set<ShortcutOperationID>
    public let unknown: [String]
    public private(set) var skipped: Set<ShortcutOperationID> = []

    public init(archive: ShortcutArchive, original: ShortcutConfiguration) {
        self.original = original
        configuration = original
        incoming = Set(archive.bindings.keys.compactMap(ShortcutOperationID.init(rawValue:)))
        unknown = archive.bindings.keys.filter { ShortcutOperationID(rawValue: $0) == nil }.sorted()
        for operation in incoming {
            configuration = configuration.replacing(operation, with: archive.bindings[operation.rawValue])
        }
    }

    public var changed: [ShortcutOperationID] {
        ShortcutOperationID.allCases.filter { operation in
            original.overrides[operation] != configuration.overrides[operation]
                || original.inactiveMigration.filter { $0.operation == operation }
                    != configuration.inactiveMigration.filter { $0.operation == operation }
        }
    }

    /// Keep the entire original assignment for this operation, including the absence of an override.
    public mutating func skip(_ operation: ShortcutOperationID) {
        skipped.insert(operation)
        let restored = configuration.replacing(operation, with: original.overrides[operation])
        configuration = ShortcutConfiguration(
            overrides: restored.overrides,
            inactiveMigration: restored.inactiveMigration
                + original.inactiveMigration.filter { $0.operation == operation })
    }

    /// Only the conflicting aliases are removed from the losing owners.
    public mutating func keep(_ operation: ShortcutOperationID, key: ShortcutCombination, validator: ShortcutValidator)
    {
        let conflicts = validator.conflicts(for: operation, keys: [key], in: configuration)
        for owner in conflicts.flatMap(\.owners) {
            configuration = configuration.replacing(
                owner.operation,
                with: configuration.keys(for: owner.operation).filter {
                    !validator.environment.matches($0, owner.binding.combination)
                })
        }
    }

    public func issues(using validator: ShortcutValidator) -> [ShortcutValidationIssue] {
        // Previously unavailable system reservations remain visible but do not block unrelated imports.
        validator.issues(in: configuration).filter {
            incoming.subtracting(skipped).contains($0.operation) || $0.code != .systemReserved
        }
    }

    public func plan(using validator: ShortcutValidator) throws -> ShortcutChangePlan {
        let issues = issues(using: validator)
        guard issues.isEmpty else { throw ShortcutModelError.validation(issues) }
        let conflicts = validator.conflicts(in: configuration)
        guard conflicts.isEmpty else { throw ShortcutModelError.conflicts(conflicts) }
        return validator.changePlan(original: original, configuration: configuration, conflicts: [])
    }
}
