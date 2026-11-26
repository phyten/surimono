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
}

/// DocumentSettings.formatReading and AppPreferences.formatReadingDefaults use the same sparse map:
/// format raw value -> setting ID -> changed components. Org stays in orgReading / orgReadingDefaults,
/// whose flat field names, enum encoding and org.* identifiers predate this map.
public struct FormatReadingChoices: Codable, Equatable, Sendable {
    private var formats: [String: [String: ReadingChoice]] = [:]

    public init() {}
    public var isEmpty: Bool { formats.isEmpty }

    public func resolve(
        _ id: ReadingSettingID, for format: DocumentFormat, file: ReadingFileInstructions = .init(),
        defaults: Self = .init(), allowsFileChanges: Bool = false
    ) -> ReadingRowResolution? {
        guard let field = id.formatField, format != .org,
            let row = ReadingCatalogue.rows(for: format).first(where: { $0.id == id })
        else { return nil }
        let document = formats[format.rawValue]?[field]
        let app = defaults.formats[format.rawValue]?[field]

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

    /// Write only on an edit. The file can constrain presence, depth, or both, each with its own reason.
    /// An app-default edit uses the same method with the shipped defaults and no file instructions.
    public mutating func set(
        _ value: ReadingSettingValue, for id: ReadingSettingID, format: DocumentFormat,
        file: ReadingFileInstructions = .init(), defaults: Self = .init(), allowsFileChanges: Bool = false
    ) {
        guard let field = id.formatField,
            let row = resolve(id, for: format, file: file, defaults: defaults, allowsFileChanges: allowsFileChanges)
        else { return }
        var choice = formats[format.rawValue]?[field] ?? ReadingChoice()
        switch (value, row) {
        case (.toggle(let value), .toggle(let present)):
            present.set(value, in: &choice.present)
        case (.outline(let enabled, let limit), .outline(let present, let depth)):
            guard !present.isLocked || enabled == present.value else { return }
            if enabled, case .levels(let count) = limit, count < 0 { return }
            present.set(enabled, in: &choice.present)
            depth.set(enabled ? limit : depth.inherited, in: &choice.depth)
        default: return
        }
        if choice == ReadingChoice() {
            formats[format.rawValue]?[field] = nil
            if formats[format.rawValue]?.isEmpty == true { formats[format.rawValue] = nil }
        } else {
            formats[format.rawValue, default: [:]][field] = choice
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formats)
    }

    /// An unrecognized format, setting or future value cannot invalidate its siblings.
    public init(from decoder: any Decoder) throws {
        let formats = try decoder.container(keyedBy: Field.self)
        for key in formats.allKeys {
            guard let format = DocumentFormat(rawValue: key.stringValue), format != .org,
                let fields = try? formats.nestedContainer(keyedBy: Field.self, forKey: key)
            else { continue }
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
