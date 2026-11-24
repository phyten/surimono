/// Stable identifiers shared by the document panel and the defaults pane.
public enum OrgSettingID: String, CaseIterable, Sendable {
    case sectionNumbers = "org.num"
    case tableOfContents = "org.toc"
    case scripts = "org.scripts"
}

/// File locations belong to the instruction, including when a document choice temporarily masks it.
public struct OrgInstructionSource: Equatable, Sendable {
    public let fileName: String?
    public let lineNumber: Int
    public let rawText: String

    public init(fileName: String?, lineNumber: Int, rawText: String) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.rawText = rawText
    }
}

private struct OrgReadingValues: Codable, Equatable, Sendable {
    var sectionNumbers: OrgReadingDefaults.Depth?
    var tableOfContents: OrgReadingDefaults.Depth?
    var scripts: OrgReadingDefaults.Scripts?
}

/// Couples each row to its typed storage in all three layers.
public struct OrgSetting<Value: Equatable & Sendable>: Sendable {
    public let id: OrgSettingID
    fileprivate let choice: WritableKeyPath<OrgReadingValues, Value?> & Sendable
    fileprivate let fallback: KeyPath<OrgReadingDefaults, Value> & Sendable
}

extension OrgSetting where Value == OrgReadingDefaults.Depth {
    public static let sectionNumbers = Self(id: .sectionNumbers, choice: \.sectionNumbers, fallback: \.sectionNumbers)
    public static let tableOfContents = Self(
        id: .tableOfContents, choice: \.tableOfContents, fallback: \.tableOfContents)
}

extension OrgSetting where Value == OrgReadingDefaults.Scripts {
    public static let scripts = Self(id: .scripts, choice: \.scripts, fallback: \.scripts)
}

public struct OrgFileInstructions: Equatable, Sendable {
    fileprivate var values = OrgReadingValues()
    fileprivate var sources: [OrgSettingID: OrgInstructionSource] = [:]
    fileprivate var notes: [OrgSettingID: [OrgInstructionSource]] = [:]

    public init() {}

    public mutating func record<Value>(_ value: Value, for key: OrgSetting<Value>, source: OrgInstructionSource) {
        values[keyPath: key.choice] = value
        sources[key.id] = source
    }

    public mutating func note(_ source: OrgInstructionSource, for id: OrgSettingID) {
        notes[id, default: []].append(source)
    }

    public var hasWholeDocumentInstructions: Bool { !sources.isEmpty }
}

public struct OrgDocumentReadingSettings: Codable, Equatable, Sendable {
    fileprivate var values = OrgReadingValues()
    public fileprivate(set) var allowsFileChanges = false

    public init() {}

    // Keep a record sparse even when enabling the switch is the only choice.
    private enum CodingKeys: String, CodingKey { case allowsFileChanges }

    public init(from decoder: any Decoder) throws {
        values = try OrgReadingValues(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        allowsFileChanges = try fields.decodeIfPresent(Bool.self, forKey: .allowsFileChanges) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
        if allowsFileChanges {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(true, forKey: .allowsFileChanges)
        }
    }

    public var changedCount: Int {
        [values.sectionNumbers != nil, values.tableOfContents != nil, values.scripts != nil].count(where: { $0 })
    }

    /// An empty selection has no line to copy. Only deliberate choices belong in another file.
    public var optionsLine: String? {
        let tokens = [
            values.sectionNumbers.map { "num:" + $0.token },
            values.tableOfContents.map { "toc:" + $0.token },
            values.scripts.map { "^:" + $0.token },
        ].compactMap { $0 }
        return tokens.isEmpty ? nil : "#+OPTIONS: " + tokens.joined(separator: " ")
    }
}

extension OrgReadingDefaults.Depth {
    fileprivate var token: String {
        switch self {
        case .off: "nil"
        case .all: "t"
        case .levels(let depth): depth > 0 ? String(depth) : "nil"
        }
    }
}

extension OrgReadingDefaults.Scripts {
    fileprivate var token: String {
        switch self {
        case .off: "nil"
        case .braces: "{}"
        case .all: "t"
        }
    }
}

public enum OrgReadingLayer: Equatable, Sendable { case file, document, app }

public struct OrgResolvedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let layer: OrgReadingLayer
    /// Where the reset arrow leads, even when the document currently wins.
    public let inherited: Value
    public let source: OrgInstructionSource?
    public let notes: [OrgInstructionSource]
}

public struct OrgReadingSettings: Equatable, Sendable {
    public var defaults: OrgReadingDefaults
    public private(set) var document: OrgDocumentReadingSettings

    public init(defaults: OrgReadingDefaults = .surimono, document: OrgDocumentReadingSettings = .init()) {
        self.defaults = defaults
        self.document = document
    }

    public func resolve<Value>(_ key: OrgSetting<Value>, file: OrgFileInstructions) -> OrgResolvedSetting<Value> {
        let source = file.sources[key.id]
        let inherited = file.values[keyPath: key.choice] ?? defaults[keyPath: key.fallback]
        let choice = source == nil || document.allowsFileChanges ? document.values[keyPath: key.choice] : nil
        return OrgResolvedSetting(
            value: choice ?? inherited, layer: choice != nil ? .document : (source == nil ? .app : .file),
            inherited: inherited, source: source, notes: file.notes[key.id] ?? [])
    }

    /// Compare only on an edit. A later change to the app default must not erase a deliberate choice.
    public mutating func set<Value>(_ value: Value, for key: OrgSetting<Value>, file: OrgFileInstructions) {
        let row = resolve(key, file: file)
        guard row.source == nil || document.allowsFileChanges else { return }
        document.values[keyPath: key.choice] = value == row.inherited ? nil : value
    }

    /// Count and apply the very same transition so the confirmation matches what will be lost.
    private func lockingFileInstructions(_ file: OrgFileInstructions) -> OrgDocumentReadingSettings {
        guard document.allowsFileChanges else { return document }
        var locked = document
        locked.allowsFileChanges = false
        if file.sources[.sectionNumbers] != nil { locked.values.sectionNumbers = nil }
        if file.sources[.tableOfContents] != nil { locked.values.tableOfContents = nil }
        if file.sources[.scripts] != nil { locked.values.scripts = nil }
        return locked
    }

    public func fileOverrideCount(file: OrgFileInstructions) -> Int {
        document.changedCount - lockingFileInstructions(file).changedCount
    }

    public mutating func setAllowsFileChanges(_ allows: Bool, file: OrgFileInstructions) {
        if allows {
            document.allowsFileChanges = true
        } else {
            document = lockingFileInstructions(file)
        }
    }
}
