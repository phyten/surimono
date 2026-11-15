import Foundation

public enum BandEntry: Equatable, Hashable, Sendable {
    case part(BandLayout.Item)
    case separator

    // The @ namespace is reserved for furniture, never for part identifiers.
    public static let separatorToken = "@separator"

    public var item: BandLayout.Item? {
        if case .part(let item) = self { return item }
        return nil
    }

    public var storedValue: String {
        switch self {
        case .part(let item): item.rawValue
        case .separator: Self.separatorToken
        }
    }
}

extension Array where Element == BandEntry {
    public func contains(_ item: BandLayout.Item) -> Bool { contains(.part(item)) }
}

public enum BandZoneID: String, Codable, CaseIterable, Sendable {
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"
}

public enum BandDestination: Equatable, Hashable, Sendable {
    case zone(BandZoneID)
    case unused

    static let ordered: [Self] = BandZoneID.allCases.map { .zone($0) } + [.unused]
}

public enum BandArrangementIssue: Equatable, Sendable {
    case missing(BandLayout.Item)
    case duplicate(BandLayout.Item)
    case printIsUnused
    case bottomZoneInTopOnly(BandZoneID)
}

public enum BandArrangementMoveError: Error, Equatable, Sendable {
    case invalidArrangement([BandArrangementIssue])
    case printIsRequired
    case invalidDestination
    case missingItem
    case invalidSuccessor
    case invalidIndex
    case notSeparator
}

/// Unknown IDs retain their zone and insertion position so a downgrade does not erase a newer part.
public struct BandUnknownPlacement: Equatable, Sendable {
    public var id: String
    public var destination: BandDestination
    public var index: Int
}

public struct BandArrangement: Codable, Equatable, Sendable {
    public var topLeft: [BandEntry]
    public var topRight: [BandEntry]
    public var bottomLeft: [BandEntry]
    public var bottomRight: [BandEntry]
    public var unused: [BandLayout.Item]
    public internal(set) var unknownPlacements: [BandUnknownPlacement] = []

    public init(
        topLeft: [BandLayout.Item] = [], topRight: [BandLayout.Item] = [],
        bottomLeft: [BandLayout.Item] = [], bottomRight: [BandLayout.Item] = [], unused: [BandLayout.Item] = []
    ) {
        self.topLeft = topLeft.map(BandEntry.part)
        self.topRight = topRight.map(BandEntry.part)
        self.bottomLeft = bottomLeft.map(BandEntry.part)
        self.bottomRight = bottomRight.map(BandEntry.part)
        self.unused = unused
    }

    public init(entries: [BandZoneID: [BandEntry]], unused: [BandLayout.Item] = []) {
        topLeft = entries[.topLeft] ?? []
        topRight = entries[.topRight] ?? []
        bottomLeft = entries[.bottomLeft] ?? []
        bottomRight = entries[.bottomRight] ?? []
        self.unused = unused
    }

    public static func standard(for mode: MenuArrangement) -> Self {
        switch mode {
        case .split:
            Self(entries: [
                .topLeft: [.part(.formatBadge)], .topRight: [.part(.floatOnTop), .part(.print)],
                .bottomLeft: [
                    .part(.presentation), .separator, .part(.style), .part(.outline), .separator,
                    .part(.layout), .part(.transition), .separator, .part(.zoom), .part(.thumbnails),
                ],
                .bottomRight: [.part(.pageIndicator), .part(.pageTurn)],
            ])
        case .top:
            Self(
                entries: [
                    .topLeft: [.part(.formatBadge), .part(.pageIndicator)],
                    .topRight: [
                        .part(.presentation), .separator, .part(.style), .part(.outline), .separator,
                        .part(.layout), .part(.transition), .separator, .part(.zoom), .part(.thumbnails),
                        .separator, .part(.floatOnTop), .part(.print),
                    ],
                ], unused: [.pageTurn])
        }
    }

    public subscript(destination: BandDestination) -> [BandEntry] {
        switch destination {
        case .zone(.topLeft): topLeft
        case .zone(.topRight): topRight
        case .zone(.bottomLeft): bottomLeft
        case .zone(.bottomRight): bottomRight
        case .unused: unused.map(BandEntry.part)
        }
    }

    public subscript(zone: BandZoneID) -> [BandEntry] {
        get { self[.zone(zone)] }
        set {
            switch zone {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomLeft: bottomLeft = newValue
            case .bottomRight: bottomRight = newValue
            }
        }
    }

    public func location(of item: BandLayout.Item) -> BandDestination? {
        BandDestination.ordered.first { self[$0].contains(item) }
    }

    // The topology belongs to the variant, not to its arrays: empty bottom zones can also be a Split draft.
    public func moving(
        _ item: BandLayout.Item, to destination: BandDestination, before successor: BandLayout.Item? = nil,
        for mode: MenuArrangement
    ) throws -> Self {
        try validate(for: mode, destination: destination)
        guard let source = location(of: item), let index = self[source].firstIndex(of: .part(item)) else {
            throw BandArrangementMoveError.missingItem
        }
        let target: Int
        if let successor {
            guard let found = self[destination].firstIndex(of: .part(successor)) else {
                throw BandArrangementMoveError.invalidSuccessor
            }
            target = found
        } else {
            target = self[destination].count
        }
        return try movingEntry(at: index, from: source, to: destination, at: target, for: mode)
    }

    public func insertingSeparator(at index: Int, in zone: BandZoneID, for mode: MenuArrangement) throws -> Self {
        try validate(for: mode, destination: .zone(zone))
        guard (0...self[zone].count).contains(index) else { throw BandArrangementMoveError.invalidIndex }
        var stored = StoredBandArrangement(self)
        let rawIndex = stored.entryIndex(index, in: .zone(zone))
        stored[.zone(zone)].insert(BandEntry.separatorToken, at: rawIndex)
        return BandArrangementRepair.repair(stored, for: mode).arrangement
    }

    public func removingSeparator(at index: Int, in zone: BandZoneID, for mode: MenuArrangement) throws -> Self {
        try validate(for: mode, destination: .zone(zone))
        guard self[zone].indices.contains(index) else { throw BandArrangementMoveError.invalidIndex }
        guard self[zone][index] == .separator else { throw BandArrangementMoveError.notSeparator }
        return try movingEntry(at: index, from: .zone(zone), to: .unused, at: unused.count, for: mode)
    }

    // Both indexes refer to the draft before removal; dropping before self or immediately after self is a no-op.
    // Unknown IDs are not editor chips, but raw edits keep them beside the surviving entries when indexes shift.
    public func movingEntry(
        at index: Int, from source: BandDestination, to destination: BandDestination, at insertionIndex: Int,
        for mode: MenuArrangement
    ) throws -> Self {
        try validate(for: mode, destination: destination)
        guard self[source].indices.contains(index), (0...self[destination].count).contains(insertionIndex) else {
            throw BandArrangementMoveError.invalidIndex
        }
        let entry = self[source][index]
        guard entry != .part(.print) || destination != .unused else { throw BandArrangementMoveError.printIsRequired }
        if source == destination, insertionIndex == index || insertionIndex == index + 1 { return self }
        var stored = StoredBandArrangement(self)
        let rawSource = stored.entryIndex(index, in: source)
        var rawTarget = stored.entryIndex(insertionIndex, in: destination)
        stored[source].remove(at: rawSource)
        if source == destination, rawSource < rawTarget { rawTarget -= 1 }
        if entry != .separator || destination != .unused {
            stored[destination].insert(entry.storedValue, at: rawTarget)
        }
        return BandArrangementRepair.repair(stored, for: mode).arrangement
    }

    private func validate(for mode: MenuArrangement, destination: BandDestination) throws {
        let issues = BandArrangementValidation.issues(in: self, for: mode)
        guard issues.isEmpty else { throw BandArrangementMoveError.invalidArrangement(issues) }
        if mode == .top, destination == .zone(.bottomLeft) || destination == .zone(.bottomRight) {
            throw BandArrangementMoveError.invalidDestination
        }
    }

    public init(from decoder: any Decoder) throws {
        self = BandArrangementRepair.repair(try StoredBandArrangement(from: decoder), for: .split).arrangement
    }

    public func encode(to encoder: any Encoder) throws {
        try StoredBandArrangement(self).encode(to: encoder)
    }
}

public enum BandArrangementValidation {
    public static func issues(in arrangement: BandArrangement, for mode: MenuArrangement) -> [BandArrangementIssue] {
        let all = BandDestination.ordered.flatMap { arrangement[$0].compactMap(\.item) }
        var result: [BandArrangementIssue] = []
        for item in BandLayout.Item.allCases {
            let count = all.filter { $0 == item }.count
            if count == 0 { result.append(.missing(item)) }
            if count > 1 { result.append(.duplicate(item)) }
        }
        if arrangement.unused.contains(.print) { result.append(.printIsUnused) }
        if mode == .top {
            if !arrangement.bottomLeft.isEmpty { result.append(.bottomZoneInTopOnly(.bottomLeft)) }
            if !arrangement.bottomRight.isEmpty { result.append(.bottomZoneInTopOnly(.bottomRight)) }
        }
        return result
    }
}

/// Strings are decoded before runtime IDs, so one future ID cannot invalidate a whole layout.
public struct StoredBandArrangement: Codable, Equatable, Sendable {
    public var topLeft: [String]
    public var topRight: [String]
    public var bottomLeft: [String]
    public var bottomRight: [String]
    public var unused: [String]

    public init(
        topLeft: [String] = [], topRight: [String] = [], bottomLeft: [String] = [], bottomRight: [String] = [],
        unused: [String] = []
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.unused = unused
    }

    public init(_ arrangement: BandArrangement) {
        self.init()
        for destination in BandDestination.ordered {
            self[destination] = arrangement[destination].map(\.storedValue)
            for unknown in arrangement.unknownPlacements.filter({ $0.destination == destination }).sorted(by: {
                $0.index < $1.index
            }) {
                self[destination].insert(unknown.id, at: min(max(0, unknown.index), self[destination].count))
            }
        }
    }

    public subscript(destination: BandDestination) -> [String] {
        get {
            switch destination {
            case .zone(.topLeft): topLeft
            case .zone(.topRight): topRight
            case .zone(.bottomLeft): bottomLeft
            case .zone(.bottomRight): bottomRight
            case .unused: unused
            }
        }
        set {
            switch destination {
            case .zone(.topLeft): topLeft = newValue
            case .zone(.topRight): topRight = newValue
            case .zone(.bottomLeft): bottomLeft = newValue
            case .zone(.bottomRight): bottomRight = newValue
            case .unused: unused = newValue
            }
        }
    }

    fileprivate func entryIndex(_ index: Int, in destination: BandDestination) -> Int {
        let entries = self[destination].indices.filter {
            self[destination][$0] == BandEntry.separatorToken || BandLayout.Item(rawValue: self[destination][$0]) != nil
        }
        return index < entries.count ? entries[index] : self[destination].count
    }

    private enum CodingKeys: String, CodingKey { case topLeft, topRight, bottomLeft, bottomRight, unused }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing arrays are older records; arrays of the wrong type make this variant recover from Standard.
        topLeft = try values.decodeIfPresent([String].self, forKey: .topLeft) ?? []
        topRight = try values.decodeIfPresent([String].self, forKey: .topRight) ?? []
        bottomLeft = try values.decodeIfPresent([String].self, forKey: .bottomLeft) ?? []
        bottomRight = try values.decodeIfPresent([String].self, forKey: .bottomRight) ?? []
        unused = try values.decodeIfPresent([String].self, forKey: .unused) ?? []
    }
}

public enum BandRepairNotice: Equatable, Sendable {
    case removedUnusedSeparator
    case unknownID(String)
    case duplicate(BandLayout.Item)
    case addedToUnused(BandLayout.Item)
    case restoredPrint
    case movedBottomZones
    case recoveredVariant(MenuArrangement)
    case invalidRecord(Int)
    case duplicateIdentity(UUID)
    case duplicateName(UUID)
    case missingActiveSet
    case malformedStore
    case unsupportedSchema(Int)
}

public struct BandRepairResult: Equatable, Sendable {
    public var arrangement: BandArrangement
    public var notices: [BandRepairNotice]

    public var stored: StoredBandArrangement { StoredBandArrangement(arrangement) }
}

public enum BandArrangementRepair {
    public static func repair(
        _ stored: StoredBandArrangement, for mode: MenuArrangement,
        knownItems: [BandLayout.Item] = BandLayout.Item.allCases
    ) -> BandRepairResult {
        var stored = stored
        var notices: [BandRepairNotice] = []
        if mode == .top, !stored.bottomLeft.isEmpty || !stored.bottomRight.isEmpty {
            stored.topLeft += stored.bottomLeft
            stored.topRight += stored.bottomRight
            stored.bottomLeft = []
            stored.bottomRight = []
            notices.append(.movedBottomZones)
        }
        var arrangement = BandArrangement()
        var seen = Set<BandLayout.Item>()
        // Print is required even when a caller supplies an older catalog for migration tests.
        let known = Set(knownItems).union([.print])
        for destination in BandDestination.ordered {
            var retainedCount = 0
            for id in stored[destination] {
                if id == BandEntry.separatorToken {
                    if case .zone(let zone) = destination {
                        arrangement[zone].append(.separator)
                        retainedCount += 1
                    } else {
                        notices.append(.removedUnusedSeparator)
                    }
                    continue
                }
                guard let item = BandLayout.Item(rawValue: id), known.contains(item) else {
                    arrangement.unknownPlacements.append(.init(id: id, destination: destination, index: retainedCount))
                    retainedCount += 1
                    notices.append(.unknownID(id))
                    continue
                }
                if destination == .unused, item == .print {
                    if seen.contains(.print) { notices.append(.duplicate(.print)) }
                    continue
                }
                guard seen.insert(item).inserted else {
                    notices.append(.duplicate(item))
                    continue
                }
                if case .zone(let zone) = destination {
                    arrangement[zone].append(.part(item))
                } else {
                    arrangement.unused.append(item)
                }
                retainedCount += 1
            }
        }
        if !seen.contains(.print) {
            arrangement.topRight.append(.part(.print))
            notices.append(.restoredPrint)
        }
        for item in BandLayout.Item.allCases where known.contains(item) && item != .print && !seen.contains(item) {
            arrangement.unused.append(item)
            notices.append(.addedToUnused(item))
        }
        return BandRepairResult(arrangement: arrangement, notices: notices)
    }
}
