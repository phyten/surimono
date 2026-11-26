extension DocumentFormat {
    public var usesFormatReadingSettings: Bool { [.markdown, .quarto, .rMarkdown, .rst, .mediawiki].contains(self) }
}

/// One persisted row in the new formats. Missing components follow the layer below.
private struct ReadingChoice: Codable, Equatable, Sendable {
    var present: Bool?
    var depth: ReadingDepth?

    init() {}

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        present = try? fields.decodeIfPresent(Bool.self, forKey: .present)
        depth = try? fields.decodeIfPresent(ReadingDepth.self, forKey: .depth)
    }
}

public enum ReadingRowResolution: Equatable, Sendable {
    case toggle(ReadingResolution<Bool>)
    case outline(present: ReadingResolution<Bool>, depth: ReadingResolution<ReadingDepth>)

    public func allowsOutline(present enabled: Bool, depth limit: ReadingDepth) -> Bool {
        guard case .outline(let present, let depth) = self else { return false }
        if enabled, case .levels(let count) = limit, count < 0 { return false }
        return (!present.isLocked || enabled == present.value) && (!enabled || !depth.isLocked || limit == depth.value)
    }
}

/// DocumentSettings.formatReading and AppPreferences.formatReadingDefaults use the same sparse map:
/// format raw value -> setting ID -> changed components. Org stays in orgReading / orgReadingDefaults,
/// whose flat field names, enum encoding and org.* identifiers predate this map.
public struct FormatReadingChoices: Codable, Equatable, Sendable {
    private var formats: [String: [String: ReadingChoice]] = [:]

    private var unlockedFormats: Set<DocumentFormat> = []

    public init() {}
    public var isEmpty: Bool { formats.isEmpty && unlockedFormats.isEmpty }

    /// Without a presence choice at any layer, the reader keeps the style's heading counters.
    public func usesStyleForSectionNumbers(
        for format: DocumentFormat = .markdown, file: ReadingFileInstructions = .init(), defaults: Self = .init()
    ) -> Bool {
        file.present == nil && choice(.sectionNumbers, for: format)?.present == nil
            && defaults.choice(.sectionNumbers, for: format)?.present == nil
    }

    private func choice(_ id: ReadingSettingID, for format: DocumentFormat) -> ReadingChoice? {
        id.formatField.flatMap { formats[format.rawValue]?[$0] }
    }

    public func allowsFileChanges(for format: DocumentFormat) -> Bool { unlockedFormats.contains(format) }

    public mutating func setAllowsFileChanges(_ allows: Bool, for format: DocumentFormat) {
        if allows { unlockedFormats.insert(format) } else { unlockedFormats.remove(format) }
    }

    public func restricted(to included: Set<DocumentFormat>) -> Self {
        var result = Self()
        for format in included {
            result.formats[format.rawValue] = formats[format.rawValue]
        }
        result.unlockedFormats = unlockedFormats.intersection(included)
        return result
    }

    public func resolve(
        _ id: ReadingSettingID, for format: DocumentFormat, file: ReadingFileInstructions = .init(),
        defaults: Self = .init(), allowsFileChanges: Bool? = nil
    ) -> ReadingRowResolution? {
        guard id.formatField != nil, format != .org,
            let row = ReadingCatalogue.rows(for: format).first(where: { $0.id == id })
        else { return nil }
        let allowsFileChanges = allowsFileChanges ?? self.allowsFileChanges(for: format)
        let document = choice(id, for: format)
        let app = defaults.choice(id, for: format)

        func presence(_ shipped: Bool) -> ReadingResolution<Bool> {
            ReadingResolution(
                file: file.present, document: document?.present, app: app?.present ?? shipped,
                allowsFileChanges: allowsFileChanges)
        }

        switch row.shipped {
        case .toggle(let shipped):
            return .toggle(presence(shipped))
        case .outline(let present, let depth):
            return .outline(
                present: presence(present),
                depth: ReadingResolution(
                    file: file.depth, document: document?.depth, app: app?.depth ?? depth,
                    allowsFileChanges: allowsFileChanges))
        default: return nil
        }
    }

    public func leadContents(
        for format: DocumentFormat, file: ReadingFileInstructions = .init(), defaults: Self = .init()
    ) -> ReadingDepth? {
        guard
            case .outline(let present, let depth) = resolve(
                .tableOfContents, for: format, file: file, defaults: defaults),
            present.value
        else { return nil }
        return depth.value
    }

    /// Write only on an edit. The file can constrain presence, depth, or both, each with its own reason.
    /// An app-default edit uses the same method with the shipped defaults and no file instructions.
    public mutating func set(
        _ value: ReadingSettingValue, for id: ReadingSettingID, format: DocumentFormat,
        file: ReadingFileInstructions = .init(), defaults: Self = .init(), allowsFileChanges: Bool? = nil
    ) {
        guard let field = id.formatField,
            let row = resolve(id, for: format, file: file, defaults: defaults, allowsFileChanges: allowsFileChanges)
        else { return }
        var choice = formats[format.rawValue]?[field] ?? ReadingChoice()
        func setPresence(_ value: Bool, _ present: ReadingResolution<Bool>) {
            if format.usesFormatReadingSettings, id == .sectionNumbers, !value, !present.isLocked {
                // An explicit None suppresses the style's counters even when the inherited value is false.
                choice.present = false
            } else {
                present.set(value, in: &choice.present)
            }
        }
        switch (value, row) {
        case (.toggle(let value), .toggle(let present)):
            setPresence(value, present)
        case (.outline(let enabled, let limit), .outline(let present, let depth)):
            // Refuse the whole edit when either locked component would have to change: no partial writes.
            guard row.allowsOutline(present: enabled, depth: limit) else { return }
            // One control carries both components. Write only the one the reader touched, so choosing a
            // depth never drops a stored presence, and switching off keeps the depth for switching back on.
            if !enabled || !present.value { setPresence(enabled, present) }
            if enabled { depth.set(limit, in: &choice.depth) }
        default: return
        }
        store(choice, field: field, format: format)
    }

    /// Removing a row also removes a remembered depth while presence is off.
    public mutating func revert(
        _ id: ReadingSettingID, for format: DocumentFormat, fileOnly: ReadingFileInstructions? = nil
    ) {
        guard let field = id.formatField, var choice = formats[format.rawValue]?[field] else { return }
        if fileOnly == nil || fileOnly?.present != nil { choice.present = nil }
        if fileOnly == nil || fileOnly?.depth != nil { choice.depth = nil }
        store(choice, field: field, format: format)
    }

    /// A legacy finish supplies only components that have no newer document choice.
    package mutating func inheritMissingLeadContents(from migrated: Self, for format: DocumentFormat) {
        guard let field = ReadingSettingID.tableOfContents.formatField,
            let legacy = migrated.choice(.tableOfContents, for: format)
        else { return }
        var lead = choice(.tableOfContents, for: format) ?? ReadingChoice()
        lead.present = lead.present ?? legacy.present
        lead.depth = lead.depth ?? legacy.depth
        store(lead, field: field, format: format)
    }

    private mutating func store(_ choice: ReadingChoice, field: String, format: DocumentFormat) {
        if choice == ReadingChoice() {
            formats[format.rawValue]?[field] = nil
            if formats[format.rawValue]?.isEmpty == true { formats[format.rawValue] = nil }
        } else {
            formats[format.rawValue, default: [:]][field] = choice
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Field.self)
        for name in Set(formats.keys).union(unlockedFormats.map(\.rawValue)) {
            var fields = container.nestedContainer(keyedBy: Field.self, forKey: Field(stringValue: name))
            for (field, choice) in formats[name] ?? [:] {
                try fields.encode(choice, forKey: Field(stringValue: field))
            }
            if let format = DocumentFormat(rawValue: name), allowsFileChanges(for: format) {
                try fields.encode(true, forKey: Field(stringValue: "allowsFileChanges"))
            }
        }
    }

    /// An unrecognized format, setting or future value cannot invalidate its siblings.
    public init(from decoder: any Decoder) throws {
        let formats = try decoder.container(keyedBy: Field.self)
        for key in formats.allKeys {
            guard let format = DocumentFormat(rawValue: key.stringValue), format != .org,
                let fields = try? formats.nestedContainer(keyedBy: Field.self, forKey: key)
            else { continue }
            if (try? fields.decode(Bool.self, forKey: Field(stringValue: "allowsFileChanges"))) == true {
                unlockedFormats.insert(format)
            }
            for row in ReadingCatalogue.rows(for: format) {
                guard let name = row.id.formatField,
                    var choice = try? fields.decode(ReadingChoice.self, forKey: Field(stringValue: name))
                else { continue }
                if case .toggle = row.shipped { choice.depth = nil }
                if choice != ReadingChoice() { self.formats[key.stringValue, default: [:]][name] = choice }
            }
        }
    }

    private struct Field: CodingKey {
        var stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
}

extension ReadingSettingID {
    fileprivate var formatField: String? {
        switch self {
        case .sectionNumbers: "sectionNumbers"
        case .tableOfContents: "tableOfContents"
        case .preserveBreaks: "preserveBreaks"
        default: nil
        }
    }
}
