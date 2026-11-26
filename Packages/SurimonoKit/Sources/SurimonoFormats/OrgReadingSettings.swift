import OSLog

/// Stable identifiers shared by the document panel and the defaults pane.
public typealias OrgSettingID = ReadingSettingID

extension OrgSettingID {
    public var token: String {
        switch self {
        case .sectionNumbers: "num"
        case .tableOfContents: "toc"
        case .headlineLevels: "H"
        case .tags: "tags"
        case .scripts: "^"
        case .preserveBreaks: "\\n"
        case .emphasis: "*"
        case .math: "tex"
        case .clocks: "c"
        case .planning: "p"
        case .priority: "pri"
        case .todo: "todo"
        case .statistics: "stat"
        case .tasks: "tasks"
        case .title: "title"
        case .author: "author"
        case .date: "date"
        case .drawers: "d"
        case .properties: "prop"
        case .timestamps: "<"
        case .footnotes: "f"
        case .tables: "|"
        case .fixedWidth: ":"
        case .archived: "arch"
        }
    }
}

public typealias OrgInstructionSource = ReadingInstructionSource

private struct OrgReadingValues: Codable, Equatable, Sendable {
    var sectionNumbers: OrgReadingDefaults.Depth?
    var tableOfContents: OrgReadingDefaults.Depth?
    var scripts: OrgReadingDefaults.Scripts?
    var headlineLevels: Int?
    var tags: OrgReadingDefaults.Tags?
    var preserveBreaks: Bool?
    var emphasis: Bool?
    var math: OrgReadingDefaults.Math?
    var clocks: Bool?
    var planning: Bool?
    var priority: Bool?
    var todo: Bool?
    var statistics: Bool?
    var tasks: OrgReadingDefaults.Tasks?
    var title: Bool?
    var author: Bool?
    var date: Bool?
    var drawers: OrgReadingDefaults.Names?
    var properties: OrgReadingDefaults.Names?
    var timestamps: OrgReadingDefaults.Timestamps?
    var footnotes: Bool?
    var tables: Bool?
    var fixedWidth: Bool?
    var archived: OrgReadingDefaults.Archived?

    init() {}

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sectionNumbers = fields.orgValue(for: .sectionNumbers)
        tableOfContents = fields.orgValue(for: .tableOfContents)
        scripts = fields.orgValue(for: .scripts)
        headlineLevels = fields.orgValue(for: .headlineLevels)
        tags = fields.orgValue(for: .tags)
        preserveBreaks = fields.orgValue(for: .preserveBreaks)
        emphasis = fields.orgValue(for: .emphasis)
        math = fields.orgValue(for: .math)
        clocks = fields.orgValue(for: .clocks)
        planning = fields.orgValue(for: .planning)
        priority = fields.orgValue(for: .priority)
        todo = fields.orgValue(for: .todo)
        statistics = fields.orgValue(for: .statistics)
        tasks = fields.orgValue(for: .tasks)
        title = fields.orgValue(for: .title)
        author = fields.orgValue(for: .author)
        date = fields.orgValue(for: .date)
        drawers = fields.orgValue(for: .drawers)
        properties = fields.orgValue(for: .properties)
        timestamps = fields.orgValue(for: .timestamps)
        footnotes = fields.orgValue(for: .footnotes)
        tables = fields.orgValue(for: .tables)
        fixedWidth = fields.orgValue(for: .fixedWidth)
        archived = fields.orgValue(for: .archived)
    }

}

extension KeyedDecodingContainer {
    fileprivate func orgValue<Value: Decodable>(for key: Key) -> Value? {
        do {
            return try decodeIfPresent(Value.self, forKey: key)
        } catch {
            // Log only the schema field, never the contents of a user's settings.
            Logger(subsystem: "app.surimono.Surimono", category: "OrgReading")
                .warning("Ignoring incompatible saved field: \(key.stringValue, privacy: .public)")
            return nil
        }
    }
}

/// Couples each row to its typed storage in all three layers.
public struct OrgSetting<Value: Equatable & Sendable>: Sendable {
    public let id: OrgSettingID
    fileprivate let choice: WritableKeyPath<OrgReadingValues, Value?> & Sendable
    public let fallback: WritableKeyPath<OrgReadingDefaults, Value> & Sendable
}

extension OrgSetting where Value == OrgReadingDefaults.Depth {
    public static let sectionNumbers = Self(id: .sectionNumbers, choice: \.sectionNumbers, fallback: \.sectionNumbers)
    public static let tableOfContents = Self(
        id: .tableOfContents, choice: \.tableOfContents, fallback: \.tableOfContents)
}

extension OrgSetting where Value == OrgReadingDefaults.Scripts {
    public static let scripts = Self(id: .scripts, choice: \.scripts, fallback: \.scripts)
}

extension OrgSetting where Value == Int {
    public static let headlineLevels = Self(id: .headlineLevels, choice: \.headlineLevels, fallback: \.headlineLevels)
}

extension OrgSetting where Value == OrgReadingDefaults.Tags {
    public static let tags = Self(id: .tags, choice: \.tags, fallback: \.tags)
}

extension OrgSetting where Value == Bool {
    public static let preserveBreaks = Self(id: .preserveBreaks, choice: \.preserveBreaks, fallback: \.preserveBreaks)
    public static let emphasis = Self(id: .emphasis, choice: \.emphasis, fallback: \.emphasis)
    public static let clocks = Self(id: .clocks, choice: \.clocks, fallback: \.clocks)
    public static let planning = Self(id: .planning, choice: \.planning, fallback: \.planning)
    public static let priority = Self(id: .priority, choice: \.priority, fallback: \.priority)
    public static let todo = Self(id: .todo, choice: \.todo, fallback: \.todo)
    public static let statistics = Self(id: .statistics, choice: \.statistics, fallback: \.statistics)
    public static let title = Self(id: .title, choice: \.title, fallback: \.title)
    public static let author = Self(id: .author, choice: \.author, fallback: \.author)
    public static let date = Self(id: .date, choice: \.date, fallback: \.date)
    public static let footnotes = Self(id: .footnotes, choice: \.footnotes, fallback: \.footnotes)
    public static let tables = Self(id: .tables, choice: \.tables, fallback: \.tables)
    public static let fixedWidth = Self(id: .fixedWidth, choice: \.fixedWidth, fallback: \.fixedWidth)
}

extension OrgSetting where Value == OrgReadingDefaults.Math {
    public static let math = Self(id: .math, choice: \.math, fallback: \.math)
}

extension OrgSetting where Value == OrgReadingDefaults.Tasks {
    public static let tasks = Self(id: .tasks, choice: \.tasks, fallback: \.tasks)
}

extension OrgSetting where Value == OrgReadingDefaults.Names {
    public static let drawers = Self(id: .drawers, choice: \.drawers, fallback: \.drawers)
    public static let properties = Self(id: .properties, choice: \.properties, fallback: \.properties)
}

extension OrgSetting where Value == OrgReadingDefaults.Timestamps {
    public static let timestamps = Self(id: .timestamps, choice: \.timestamps, fallback: \.timestamps)
}

extension OrgSetting where Value == OrgReadingDefaults.Archived {
    public static let archived = Self(id: .archived, choice: \.archived, fallback: \.archived)
}

public struct OrgInstructionNote: Equatable, Sendable {
    public enum Kind: Sendable {
        case unnumberedHeading, bodyContents, excludedFromContents

        fileprivate var setting: OrgSettingID {
            switch self {
            case .unnumberedHeading: .sectionNumbers
            case .bodyContents, .excludedFromContents: .tableOfContents
            }
        }
    }

    public let kind: Kind
    public let source: OrgInstructionSource
}

public struct OrgFileInstructions: Equatable, Sendable {
    /// Source syntax, including task elements hidden by reading settings.
    public internal(set) var hasTaskOrDateElements = false
    fileprivate var values = OrgReadingValues()
    fileprivate var sources: [OrgSettingID: OrgInstructionSource] = [:]
    fileprivate var notes: [OrgSettingID: [OrgInstructionNote]] = [:]
    /// A subtree can exclude several headings with a single property drawer.
    public internal(set) var excludedHeadingCount = 0

    public init() {}

    public mutating func record<Value>(_ value: Value, for key: OrgSetting<Value>, source: OrgInstructionSource) {
        values[keyPath: key.choice] = value
        sources[key.id] = source
    }

    public mutating func note(_ kind: OrgInstructionNote.Kind, source: OrgInstructionSource) {
        notes[kind.setting, default: []].append(.init(kind: kind, source: source))
    }

    mutating func clearOutlineNotes() {
        notes.removeAll()
        excludedHeadingCount = 0
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
        allowsFileChanges = fields.orgValue(for: .allowsFileChanges) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
        if allowsFileChanges {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(true, forKey: .allowsFileChanges)
        }
    }

    public var changedCount: Int {
        OrgSettingRegistry.rows.count { $0.hasChoice(in: values) }
    }

    /// A newly added file instruction can mask an old choice without deleting it.
    public func changedCount(file: OrgFileInstructions) -> Int {
        OrgSettingRegistry.rows.count {
            (allowsFileChanges || file.sources[$0.id] == nil) && $0.hasChoice(in: values)
        }
    }

    /// Reverting rows leaves the reader's permission to edit file instructions in place.
    public mutating func resetValues() { values = OrgReadingValues() }

    /// An empty selection has no line to copy. Only deliberate choices belong in another file.
    public var optionsLine: String? {
        let tokens = OrgSettingRegistry.rows.compactMap { $0.token(in: values) }
        return tokens.isEmpty ? nil : "#+OPTIONS: " + tokens.joined(separator: " ")
    }
}

extension OrgReadingDefaults.Depth {
    var token: String {
        switch self {
        case .off: "nil"
        case .all: "t"
        case .levels(let depth): depth > 0 ? String(depth) : "nil"
        }
    }
}

extension OrgReadingDefaults.Scripts {
    var token: String {
        switch self {
        case .off: "nil"
        case .braces: "{}"
        case .all: "t"
        }
    }
}

public typealias OrgReadingLayer = ReadingLayer

public struct OrgResolvedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let layer: OrgReadingLayer
    /// Where the reset arrow leads, even when the document currently wins.
    public let inherited: Value
    public let source: OrgInstructionSource?
    public let isLocked: Bool
    public let notes: [OrgInstructionNote]
}

public struct OrgReadingSettings: Equatable, Sendable {
    public var defaults: OrgReadingDefaults
    public private(set) var document: OrgDocumentReadingSettings

    public init(defaults: OrgReadingDefaults = .surimono, document: OrgDocumentReadingSettings = .init()) {
        self.defaults = defaults
        self.document = document
    }

    public func resolve<Value>(_ key: OrgSetting<Value>, file: OrgFileInstructions) -> OrgResolvedSetting<Value> {
        let row = resolution(key, file: file)
        return OrgResolvedSetting(
            value: row.value, layer: row.layer, inherited: row.inherited, source: row.source,
            isLocked: row.isLocked, notes: file.notes[key.id] ?? [])
    }

    private func resolution<Value>(_ key: OrgSetting<Value>, file: OrgFileInstructions) -> ReadingResolution<Value> {
        let instruction = file.sources[key.id].flatMap { source in
            file.values[keyPath: key.choice].map { ReadingInstruction($0, source: source) }
        }
        return ReadingResolution(
            file: instruction, document: document.values[keyPath: key.choice], app: defaults[keyPath: key.fallback],
            allowsFileChanges: document.allowsFileChanges)
    }

    public mutating func set<Value>(_ value: Value, for key: OrgSetting<Value>, file: OrgFileInstructions) {
        let row = resolution(key, file: file)
        row.set(value, in: &document.values[keyPath: key.choice])
    }

    /// Count and apply the very same transition so the confirmation matches what will be lost.
    private func lockingFileInstructions(_ file: OrgFileInstructions)
        -> (locked: OrgDocumentReadingSettings, overrides: OrgDocumentReadingSettings)
    {
        var locked = document
        var overrides = OrgDocumentReadingSettings()
        if locked.allowsFileChanges {
            locked.allowsFileChanges = false
            for row in OrgSettingRegistry.rows where file.sources[row.id] != nil {
                row.moveChoice(from: &locked.values, to: &overrides.values)
            }
        }
        return (locked, overrides)
    }

    public func fileOverrides(file: OrgFileInstructions) -> OrgDocumentReadingSettings {
        lockingFileInstructions(file).overrides
    }

    public func fileOverrideCount(file: OrgFileInstructions) -> Int {
        fileOverrides(file: file).changedCount
    }

    public mutating func setAllowsFileChanges(_ allows: Bool, file: OrgFileInstructions) {
        if allows {
            document.allowsFileChanges = true
        } else {
            document = lockingFileInstructions(file).locked
        }
    }
}

/// A masked choice is not a visible edit. Count each row according to the same resolution as its control.
public struct ReadingGroupCounts: Equatable, Sendable {
    public var changed = 0
    public var file = 0
    public init() {}
}

extension OrgReadingGroup {
    public func counts(in settings: OrgReadingSettings, file: OrgFileInstructions) -> ReadingGroupCounts {
        var counts = ReadingGroupCounts()
        for row in OrgSettingRegistry.rows where self.settings.contains(row.id) {
            row.count(in: settings, file: file, into: &counts)
        }
        return counts
    }

    public func isExpanded(manual: Bool?, changed: Int, file: OrgFileInstructions?) -> Bool {
        guard isFoldable else { return true }
        return manual ?? (changed > 0 || self == .tasksAndDates && file?.hasTaskOrDateElements == true)
    }
}

/// Bulk operations visit the same typed keys as the individual controls.
private protocol OrgSettingOperations: Sendable {
    var id: OrgSettingID { get }
    func restore(_ values: OrgReadingValues, to defaults: inout OrgReadingDefaults)
    func count(in settings: OrgReadingSettings, file: OrgFileInstructions, into counts: inout ReadingGroupCounts)
    func hasChoice(in values: OrgReadingValues) -> Bool
    func token(in values: OrgReadingValues) -> String?
    func moveChoice(from source: inout OrgReadingValues, to target: inout OrgReadingValues)
    func apply(
        _ settings: OrgReadingSettings, file: OrgFileInstructions, documentOnly: Bool,
        to defaults: inout OrgReadingDefaults)
    func differs(_ lhs: OrgReadingDefaults, from rhs: OrgReadingDefaults) -> Bool
    func overwrites(_ current: OrgReadingDefaults, with preset: OrgReadingDefaults) -> Bool
}

protocol OrgOptionToken {
    var token: String { get }
}

extension OrgReadingDefaults.Depth: OrgOptionToken {}
extension OrgReadingDefaults.Scripts: OrgOptionToken {}
extension Bool: OrgOptionToken { var token: String { self ? "t" : "nil" } }
extension Int: OrgOptionToken { var token: String { String(self) } }

extension OrgSetting: OrgSettingOperations where Value: OrgOptionToken {
    fileprivate func restore(_ values: OrgReadingValues, to defaults: inout OrgReadingDefaults) {
        if let value = values[keyPath: choice] { defaults[keyPath: fallback] = value }
    }
    fileprivate func count(
        in settings: OrgReadingSettings, file: OrgFileInstructions, into counts: inout ReadingGroupCounts
    ) {
        let resolved = settings.resolve(self, file: file)
        if resolved.layer == .document { counts.changed += 1 }
        if resolved.isLocked { counts.file += 1 }
    }
    fileprivate func hasChoice(in values: OrgReadingValues) -> Bool { values[keyPath: choice] != nil }
    fileprivate func token(in values: OrgReadingValues) -> String? {
        values[keyPath: choice].map { id.token + ":" + $0.token }
    }
    fileprivate func moveChoice(from source: inout OrgReadingValues, to target: inout OrgReadingValues) {
        swap(&source[keyPath: choice], &target[keyPath: choice])
    }
    fileprivate func apply(
        _ settings: OrgReadingSettings, file: OrgFileInstructions, documentOnly: Bool,
        to defaults: inout OrgReadingDefaults
    ) {
        let row = settings.resolve(self, file: file)
        if !documentOnly || row.layer == .document { defaults[keyPath: fallback] = row.value }
    }
    fileprivate func differs(_ lhs: OrgReadingDefaults, from rhs: OrgReadingDefaults) -> Bool {
        lhs[keyPath: fallback] != rhs[keyPath: fallback]
    }
    fileprivate func overwrites(_ current: OrgReadingDefaults, with preset: OrgReadingDefaults) -> Bool {
        current[keyPath: fallback] != OrgReadingDefaults.surimono[keyPath: fallback]
            && preset[keyPath: fallback] != current[keyPath: fallback]
    }
}

private enum OrgSettingRegistry {
    static let rows: [any OrgSettingOperations] = [
        OrgSetting.sectionNumbers,
        OrgSetting.tableOfContents,
        OrgSetting.headlineLevels,
        OrgSetting.tags,
        OrgSetting.scripts,
        OrgSetting.preserveBreaks,
        OrgSetting.emphasis,
        OrgSetting.math,
        OrgSetting.planning,
        OrgSetting.clocks,
        OrgSetting.priority,
        OrgSetting.todo,
        OrgSetting.statistics,
        OrgSetting.tasks,
        OrgSetting.title,
        OrgSetting.author,
        OrgSetting.date,
        OrgSetting.drawers,
        OrgSetting.properties,
        OrgSetting.timestamps,
        OrgSetting.footnotes,
        OrgSetting.tables,
        OrgSetting.fixedWidth,
        OrgSetting.archived,
    ]
}

extension OrgReadingSettings {
    public func effectiveDefaults(file: OrgFileInstructions, documentOnly: Bool = false) -> OrgReadingDefaults {
        var result = defaults
        for row in OrgSettingRegistry.rows { row.apply(self, file: file, documentOnly: documentOnly, to: &result) }
        return result
    }
}

extension OrgReadingDefaults {
    /// Old records supply only the choices that existed when they were written.
    public init(from decoder: any Decoder) throws {
        let stored = try OrgReadingValues(from: decoder)
        self = .surimono
        for row in OrgSettingRegistry.rows { row.restore(stored, to: &self) }
    }

    public func changedIDs(from defaults: Self) -> Set<OrgSettingID> {
        Set(OrgSettingRegistry.rows.compactMap { $0.differs(self, from: defaults) ? $0.id : nil })
    }

    public func overwritesChanges(in current: Self) -> Bool {
        OrgSettingRegistry.rows.contains { $0.overwrites(current, with: self) }
    }
}
