import Foundation

public struct PrintSettingSet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var layoutID: String?
    public var paperOrientation: PaperOrientation?
    public var marginsInMillimeters: Double?
    public var showsPageNumbers: Bool?
    public var themeID: String?
    public var textScale: Double?
    public var presetID: String?

    public init(id: UUID = UUID(), name: String, settings: DocumentSettings) {
        self.id = id
        self.name = name
        layoutID = settings.layoutID
        paperOrientation = settings.paperOrientation
        marginsInMillimeters = settings.printOptions?.marginsInMillimeters
        showsPageNumbers = settings.printOptions?.showsPageNumbers
        themeID = settings.themeID
        textScale = settings.textScale
        presetID = settings.presetID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layoutID, paperOrientation, marginsInMillimeters, showsPageNumbers, themeID, textScale, presetID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: values, debugDescription: "Empty set name")
        }
        // Future or malformed fields must not discard the other choices in the set.
        func field<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) -> Value? {
            try? values.decodeIfPresent(type, forKey: key)
        }
        layoutID = field(String.self, .layoutID)
        paperOrientation = field(PaperOrientation.self, .paperOrientation)
        marginsInMillimeters = field(Double.self, .marginsInMillimeters)
        showsPageNumbers = field(Bool.self, .showsPageNumbers)
        themeID = field(String.self, .themeID)
        textScale = field(Double.self, .textScale)
        presetID = field(String.self, .presetID)
    }

    /// Applying and checking a set use the same projection onto the document's available choices.
    public func applicable(to format: DocumentFormat, themeIDs: Set<String>, presetIDs: Set<String>) -> Self {
        applicable(to: [format], themeIDs: themeIDs, presetIDs: presetIDs)
    }

    public func applicable(to formats: Set<DocumentFormat>, themeIDs: Set<String>, presetIDs: Set<String>) -> Self {
        var result = self
        if let layoutID, !PrintLayout.presets.contains(where: { $0.id == layoutID }) { result.layoutID = nil }
        if !formats.contains(where: \.usesPrintTheme) {
            result.themeID = nil
            result.textScale = nil
        } else if let themeID, !themeIDs.contains(themeID) {
            result.themeID = nil
        }
        if !formats.contains(where: \.usesHTMLPreset) || presetID.map({ !presetIDs.contains($0) }) == true {
            result.presetID = nil
        }
        if let value = result.marginsInMillimeters, !value.isFinite || value < 0 { result.marginsInMillimeters = nil }
        if let value = result.textScale, !TextScale.steps.contains(value) { result.textScale = nil }
        return result
    }

    public func matches(_ settings: DocumentSettings) -> Bool {
        let comparisons: [Bool?] = [
            layoutID.map { $0 == settings.layoutID },
            paperOrientation.map { $0 == settings.paperOrientation },
            marginsInMillimeters.map { $0 == settings.printOptions?.marginsInMillimeters },
            showsPageNumbers.map { $0 == settings.printOptions?.showsPageNumbers },
            themeID.map { $0 == settings.themeID },
            textScale.map { $0 == settings.textScale },
            presetID.map { $0 == settings.presetID },
        ]
        let present = comparisons.compactMap { $0 }
        return !present.isEmpty && present.allSatisfy { $0 }
    }
}
