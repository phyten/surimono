import Foundation

public struct BandArrangementVariants: Codable, Equatable, Sendable {
    public var split: BandArrangement
    public var top: BandArrangement
    public internal(set) var repairNotices: [BandRepairNotice] = []

    public init(split: BandArrangement = .standard(for: .split), top: BandArrangement = .standard(for: .top)) {
        self.split = split
        self.top = top
    }

    public func arrangement(for mode: MenuArrangement) -> BandArrangement { mode == .split ? split : top }

    private enum CodingKeys: String, CodingKey { case split, top }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func variant(_ key: CodingKeys, mode: MenuArrangement) -> BandRepairResult {
            guard let stored = try? values.decode(StoredBandArrangement.self, forKey: key) else {
                return BandRepairResult(
                    arrangement: .standard(for: mode, knownItems: decoder.bandKnownItems),
                    notices: [.recoveredVariant(mode)])
            }
            return BandArrangementRepair.repair(stored, for: mode, knownItems: decoder.bandKnownItems)
        }
        let split = variant(.split, mode: .split)
        let top = variant(.top, mode: .top)
        self.split = split.arrangement
        self.top = top.arrangement
        repairNotices = split.notices + top.notices
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Notices describe the load, not the saved layout or whether an editor draft has changed.
        lhs.split == rhs.split && lhs.top == rhs.top
    }
}

public struct BandArrangementSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layouts: BandArrangementVariants

    public init(id: UUID = UUID(), name: String, layouts: BandArrangementVariants = .init()) {
        self.id = id
        self.name = name
        self.layouts = layouts
    }

    private enum CodingKeys: String, CodingKey { case id, name, layouts }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BandArrangementStoreError.emptyName }
        // A broken layout must not discard a valid identity and its other saved metadata.
        if let variants = try? values.decode(BandArrangementVariants.self, forKey: .layouts) {
            layouts = variants
        } else {
            layouts = BandArrangementVariants(
                split: .standard(for: .split, knownItems: decoder.bandKnownItems),
                top: .standard(for: .top, knownItems: decoder.bandKnownItems))
            layouts.repairNotices = [.recoveredVariant(.split), .recoveredVariant(.top)]
        }
    }
}

public enum BandArrangementSelection: Codable, Hashable, Sendable {
    case standard
    case user(UUID)

    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case standard, user }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .standard: self = .standard
        case .user: self = .user(try values.decode(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .standard: try values.encode(Kind.standard, forKey: .kind)
        case .user(let id):
            try values.encode(Kind.user, forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }
}

public enum BandArrangementStoreError: Error, Equatable, Sendable {
    case standardIsReadOnly
    case emptyName
    case duplicateName
    case duplicateIdentity
    case missingSet
    case replacementRequired
    case invalidReplacement
    case invalidLayout(MenuArrangement, [BandArrangementIssue])
    case unsupportedSchema(Int)
}

/// One value is the transaction boundary for both saved layouts and selection.
public struct BandArrangementStore: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int { Self.currentSchemaVersion }
    public private(set) var active: BandArrangementSelection = .standard
    public private(set) var sets: [BandArrangementSet] = []
    public private(set) var repairNotices: [BandRepairNotice] = []

    public init() {}

    public static func previousArrangement(named name: String) -> Self {
        var store = Self()
        var layouts = BandArrangementVariants()
        layouts.split.bottomLeft.removeAll { $0 == .part(.outline) }
        layouts.split.unused.append(.outline)
        layouts.top.topRight.removeAll { $0 == .part(.outline) }
        layouts.top.unused.append(.outline)
        // A deterministic migration identity survives repeated loads before the first explicit save.
        let id = UUID(
            uuid: (0x82, 0xA9, 0xDE, 0x17, 0x83, 0xDC, 0x4E, 0x32, 0x97, 0x56, 0x26, 0xCB, 0x8D, 0x83, 0x2F, 0x19))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.sets = [
            BandArrangementSet(id: id, name: trimmed.isEmpty ? "Previous Arrangement" : trimmed, layouts: layouts)
        ]
        store.active = .user(id)
        return store
    }

    public var activeLayouts: BandArrangementVariants {
        if case .user(let id) = active, let set = sets.first(where: { $0.id == id }) { return set.layouts }
        return BandArrangementVariants()
    }

    public func contains(_ selection: BandArrangementSelection) -> Bool {
        switch selection {
        case .standard: true
        case .user(let id): sets.contains { $0.id == id }
        }
    }

    public mutating func select(_ selection: BandArrangementSelection) throws {
        guard contains(selection) else { throw BandArrangementStoreError.missingSet }
        active = selection
    }

    public mutating func insert(
        _ set: BandArrangementSet, activate: Bool = true,
        knownItems: [BandLayout.Item] = BandLayout.Item.allCases
    ) throws {
        guard !sets.contains(where: { $0.id == set.id }) else { throw BandArrangementStoreError.duplicateIdentity }
        var set = set
        set.name = try validName(set.name)
        set.layouts = try completedLayouts(set.layouts, knownItems: knownItems)
        sets.append(set)
        if activate { active = .user(set.id) }
    }

    public mutating func overwrite(
        _ selection: BandArrangementSelection, layouts: BandArrangementVariants,
        knownItems: [BandLayout.Item] = BandLayout.Item.allCases
    ) throws {
        let index = try userIndex(selection)
        sets[index].layouts = try completedLayouts(layouts, knownItems: knownItems)
    }

    public mutating func rename(_ selection: BandArrangementSelection, to name: String) throws {
        let index = try userIndex(selection)
        let name = try validName(name, excluding: sets[index].id)
        sets[index].name = name
    }

    public mutating func delete(
        _ selection: BandArrangementSelection, replacement: BandArrangementSelection? = nil
    ) throws {
        let index = try userIndex(selection)
        if selection == active {
            guard let replacement else { throw BandArrangementStoreError.replacementRequired }
            guard replacement != selection, contains(replacement) else {
                throw BandArrangementStoreError.invalidReplacement
            }
            active = replacement
        }
        sets.remove(at: index)
    }

    /// NFC plus case/width folding with a fixed locale; accents and internal whitespace remain significant.
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func validName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BandArrangementStoreError.emptyName }
        guard !sets.contains(where: { $0.id != id && Self.normalizedName($0.name) == Self.normalizedName(name) }) else {
            throw BandArrangementStoreError.duplicateName
        }
        return name
    }

    private func userIndex(_ selection: BandArrangementSelection) throws -> Int {
        guard case .user(let id) = selection else { throw BandArrangementStoreError.standardIsReadOnly }
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw BandArrangementStoreError.missingSet }
        return index
    }

    // Saving a hand-built or older layout may omit optional parts. Complete only those omissions;
    // duplicates, a missing Print and invalid zones remain errors rather than silently repairing a draft.
    private func completedLayouts(
        _ layouts: BandArrangementVariants,
        knownItems: [BandLayout.Item] = BandLayout.Item.allCases
    ) throws -> BandArrangementVariants {
        var completed = layouts
        for mode in MenuArrangement.allCases {
            let arrangement = layouts.arrangement(for: mode)
            let issues = BandArrangementValidation.issues(in: arrangement, for: mode, knownItems: knownItems)
            let invalid = issues.filter {
                if case .missing(let item) = $0, item != .print { return false }
                return true
            }
            guard invalid.isEmpty else { throw BandArrangementStoreError.invalidLayout(mode, invalid) }
            let repaired = BandArrangementRepair.repair(
                StoredBandArrangement(arrangement), for: mode, knownItems: knownItems
            ).arrangement
            if mode == .split { completed.split = repaired } else { completed.top = repaired }
        }
        return completed
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, active, sets }

    private struct Record: Decodable {
        let value: BandArrangementSet?
        init(from decoder: any Decoder) throws { value = try? BandArrangementSet(from: decoder) }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw BandArrangementStoreError.unsupportedSchema(version) }
        let records = try values.decode([Record].self, forKey: .sets)
        var ids = Set<UUID>()
        var names = Set<String>()
        for (index, record) in records.enumerated() {
            guard let set = record.value else {
                repairNotices.append(.invalidRecord(index))
                continue
            }
            guard !ids.contains(set.id) else {
                repairNotices.append(.duplicateIdentity(set.id))
                continue
            }
            guard names.insert(Self.normalizedName(set.name)).inserted else {
                repairNotices.append(.duplicateName(set.id))
                continue
            }
            ids.insert(set.id)
            sets.append(set)
            repairNotices += set.layouts.repairNotices
        }
        if let selection = try? values.decode(BandArrangementSelection.self, forKey: .active), contains(selection) {
            active = selection
        } else {
            active = .standard
            repairNotices.append(.missingActiveSet)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(active, forKey: .active)
        try values.encode(sets, forKey: .sets)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.active == rhs.active && lhs.sets == rhs.sets }

    public static func load(
        _ data: Data?, knownItems: [BandLayout.Item] = BandLayout.Item.allCases
    ) -> BandArrangementLoadResult {
        guard let data else { return BandArrangementLoadResult(store: Self(), retainedData: nil, notices: []) }
        do {
            let decoder = JSONDecoder()
            if let key = CodingUserInfoKey.bandKnownItems { decoder.userInfo[key] = knownItems }
            let store = try decoder.decode(Self.self, from: data)
            return BandArrangementLoadResult(store: store, retainedData: nil, notices: store.repairNotices)
        } catch BandArrangementStoreError.unsupportedSchema(let version) {
            return BandArrangementLoadResult(store: Self(), retainedData: data, notices: [.unsupportedSchema(version)])
        } catch {
            return BandArrangementLoadResult(store: Self(), retainedData: data, notices: [.malformedStore])
        }
    }
}

public struct BandArrangementLoadResult: Equatable, Sendable {
    public var store: BandArrangementStore
    /// The preferences layer must not overwrite an unreadable envelope implicitly.
    public var retainedData: Data?
    public var notices: [BandRepairNotice]
}
