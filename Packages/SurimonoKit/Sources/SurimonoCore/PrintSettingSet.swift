import Foundation

public struct PrintSettingSet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var layoutID: String?
    public var paperOrientation: PaperOrientation?
    public var margins: PageMargins?
    public var linksMargins: Bool?
    public var mirrorsMargins: Bool?
    public var furniture: PageFurniture?
    public var finish: PrintFinish?
    public var themeID: String?
    public var textScale: Double?
    public var presetID: String?

    /// All four margins as one value; nil for a set with uneven margins or none at all.
    public var marginsInMillimeters: Double? { margins?.uniformValue }
    public var showsPageNumbers: Bool? { furniture.map { $0.preset != .none } }

    public init(id: UUID = UUID(), name: String, settings: DocumentSettings) {
        self.id = id
        self.name = name
        layoutID = settings.layoutID
        paperOrientation = settings.paperOrientation
        margins = settings.printOptions?.margins
        linksMargins = settings.printOptions?.linksMargins
        mirrorsMargins = settings.printOptions?.mirrorsMargins
        furniture = settings.printOptions?.furniture
        finish = settings.printFinish
        themeID = settings.themeID
        textScale = settings.textScale
        presetID = settings.presetID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layoutID, paperOrientation, margins, linksMargins, mirrorsMargins, furniture, finish, themeID,
            textScale, presetID
        case marginsInMillimeters, showsPageNumbers
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(layoutID, forKey: .layoutID)
        try values.encodeIfPresent(paperOrientation, forKey: .paperOrientation)
        try values.encodeIfPresent(margins, forKey: .margins)
        try values.encodeIfPresent(linksMargins, forKey: .linksMargins)
        try values.encodeIfPresent(mirrorsMargins, forKey: .mirrorsMargins)
        try values.encodeIfPresent(furniture, forKey: .furniture)
        try values.encodeIfPresent(finish, forKey: .finish)
        try values.encodeIfPresent(themeID, forKey: .themeID)
        try values.encodeIfPresent(textScale, forKey: .textScale)
        try values.encodeIfPresent(presetID, forKey: .presetID)
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
        // Sets saved before the four margins and the header and footer kept one margin and a switch.
        margins =
            field(PageMargins.self, .margins) ?? field(Double.self, .marginsInMillimeters).map(PageMargins.uniform)
        linksMargins = field(Bool.self, .linksMargins)
        mirrorsMargins = field(Bool.self, .mirrorsMargins)
        furniture =
            field(PageFurniture.self, .furniture)
            ?? field(Bool.self, .showsPageNumbers).map { $0 ? .pageNumber : PageFurniture() }
        finish = field(PrintFinish.self, .finish)
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
            result.finish = nil
        } else if let themeID, !themeIDs.contains(themeID) {
            result.themeID = nil
        }
        if !formats.contains(where: \.usesHTMLPreset) || presetID.map({ !presetIDs.contains($0) }) == true {
            result.presetID = nil
        }
        if let value = result.margins, !value.isValid { result.margins = nil }
        if let value = result.textScale, !TextScale.steps.contains(value) { result.textScale = nil }
        return result
    }

    public func matches(_ settings: DocumentSettings) -> Bool {
        let comparisons: [Bool?] = [
            layoutID.map { $0 == settings.layoutID },
            paperOrientation.map { $0 == settings.paperOrientation },
            margins.map { $0 == settings.printOptions?.margins },
            mirrorsMargins.map { $0 == settings.printOptions?.mirrorsMargins },
            furniture.map { $0 == settings.printOptions?.furniture },
            finish.map { $0 == (settings.printFinish ?? PrintFinish()) },
            themeID.map { $0 == settings.themeID },
            textScale.map { $0 == settings.textScale },
            presetID.map { $0 == settings.presetID },
        ]
        let present = comparisons.compactMap { $0 }
        return !present.isEmpty && present.allSatisfy { $0 }
    }

    // MARK: Built-in sets

    private static let handoutID = UUID(uuid: (0x53, 0x55, 0x52, 0x49, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))
    private static let bookID = UUID(uuid: (0x53, 0x55, 0x52, 0x49, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 2))
    private static let plainID = UUID(uuid: (0x53, 0x55, 0x52, 0x49, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3))

    public var isBuiltIn: Bool { [Self.handoutID, Self.bookID, Self.plainID].contains(id) }

    /// The sets every window offers. They are not stored, so the app can improve them; their names follow the language.
    public static func builtIns(language: String) -> [PrintSettingSet] {
        func set(
            _ id: UUID, _ names: [String: String], layout: PrintLayout, furniture: PageFurniture, h1: HeadingBreak,
            contents: PaperTOC.Mode
        ) -> PrintSettingSet {
            var options = PrintOptions()
            options.furniture = furniture
            var finish = PrintFinish()
            finish.breaks.h1 = h1
            finish.toc.mode = contents
            return PrintSettingSet(
                id: id, name: UILanguage.name(names, language: language, english: names["en"] ?? ""),
                settings: DocumentSettings(layoutID: layout.id, printOptions: options, printFinish: finish))
        }
        return [
            set(
                handoutID,
                [
                    "en": "Handout", "ja": "配布資料", "zh-Hans": "讲义", "zh-Hant": "講義", "ko": "배포 자료",
                    "fr": "Document à distribuer", "de": "Handout", "es": "Material de reparto",
                ], layout: .a4Duplex, furniture: .nameAndDate, h1: .none, contents: .hidden),
            set(
                bookID,
                [
                    "en": "Booklet with Chapters", "ja": "章立ての冊子", "zh-Hans": "分章小册子", "zh-Hant": "分章小冊子",
                    "ko": "장으로 나눈 소책자", "fr": "Livret en chapitres", "de": "Broschüre mit Kapiteln",
                    "es": "Folleto por capítulos",
                ], layout: .a4BookletA5, furniture: .name, h1: .rightPage, contents: .front),
            set(
                plainID,
                [
                    "en": "Nothing Added", "ja": "何も足さない", "zh-Hans": "不添加内容", "zh-Hant": "不添加內容",
                    "ko": "아무것도 넣지 않음", "fr": "Sans ajout", "de": "Nichts hinzufügen", "es": "Sin añadidos",
                ], layout: .a4Single, furniture: PageFurniture(), h1: .none, contents: .hidden),
        ]
    }
}
