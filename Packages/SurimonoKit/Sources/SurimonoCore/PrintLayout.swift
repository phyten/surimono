import Foundation

public enum PaperSize: String, CaseIterable, Codable, Sendable {
    case a3, a4, a5, b4, b5, letter, tabloid

    public var size: CGSize {
        let millimeters: (Double, Double) =
            switch self {
            case .a3: (297, 420)
            case .a4: (210, 297)
            case .a5: (148, 210)
            case .b4: (257, 364)
            case .b5: (182, 257)
            case .letter: (215.9, 279.4)
            case .tabloid: (279.4, 431.8)
            }
        return CGSize(width: millimeters.0 * 72 / 25.4, height: millimeters.1 * 72 / 25.4)
    }

    public var displayName: String {
        switch self {
        case .a3: "A3"
        case .a4: "A4"
        case .a5: "A5"
        case .b4: "B4 (JIS)"
        case .b5: "B5 (JIS)"
        case .letter: "Letter"
        case .tabloid: "Tabloid"
        }
    }

    public var halved: PaperSize? {
        switch self {
        case .a3: .a4
        case .a4: .a5
        case .b4: .b5
        case .tabloid: .letter
        default: nil
        }
    }
}

public enum DuplexMode: String, Codable, Sendable {
    case none, longEdge, shortEdge
}

public enum LayoutKind: String, Codable, Sendable {
    case normal, twoUp, booklet
}

public struct PrintLayout: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: LayoutKind
    public let sheet: PaperSize
    public let duplex: DuplexMode

    public enum ValidationError: Error, Sendable {
        case missingHalfSize
        case twoUpMustBeSingleSided
        case bookletMustUseShortEdge
    }

    public init(id: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) throws {
        if kind != .normal && sheet.halved == nil { throw ValidationError.missingHalfSize }
        if kind == .twoUp && duplex != .none { throw ValidationError.twoUpMustBeSingleSided }
        if kind == .booklet && duplex != .shortEdge { throw ValidationError.bookletMustUseShortEdge }
        self.init(validatedID: id, kind: kind, sheet: sheet, duplex: duplex)
    }

    private init(validatedID: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) {
        id = validatedID
        self.kind = kind
        self.sheet = sheet
        self.duplex = duplex
    }

    private enum CodingKeys: String, CodingKey { case id, kind, sheet, duplex }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id), kind: values.decode(LayoutKind.self, forKey: .kind),
            sheet: values.decode(PaperSize.self, forKey: .sheet),
            duplex: values.decode(DuplexMode.self, forKey: .duplex))
    }

    public var sheetSize: CGSize {
        kind == .normal ? sheet.size : CGSize(width: sheet.size.height, height: sheet.size.width)
    }

    public var logicalPageSize: CGSize {
        kind == .normal ? sheet.size : (sheet.halved ?? sheet).size
    }

    public var pagesPerSide: Int { kind == .normal ? 1 : 2 }

    public func displayName(language: String = "en") -> String {
        let japanese = language.lowercased().hasPrefix("ja")
        switch kind {
        case .normal:
            return "\(sheet.displayName) "
                + (duplex == .none ? (japanese ? "片面" : "Single-sided") : (japanese ? "両面" : "Duplex"))
        case .twoUp:
            return "\(sheet.displayName) " + (japanese ? "2アップ" : "2-up")
        case .booklet:
            return "\(sheet.displayName) " + (japanese ? "中綴じ" : "Booklet")
                + " → \((sheet.halved ?? sheet).displayName)"
        }
    }

    public static let a4Single = PrintLayout(validatedID: "a4Single", kind: .normal, sheet: .a4, duplex: .none)
    public static let a4Duplex = PrintLayout(validatedID: "a4Duplex", kind: .normal, sheet: .a4, duplex: .longEdge)
    public static let a3BookletA4 = PrintLayout(
        validatedID: "a3BookletA4", kind: .booklet, sheet: .a3, duplex: .shortEdge)
    public static let a4BookletA5 = PrintLayout(
        validatedID: "a4BookletA5", kind: .booklet, sheet: .a4, duplex: .shortEdge)
    public static let a3TwoUp = PrintLayout(validatedID: "a3TwoUp", kind: .twoUp, sheet: .a3, duplex: .none)
    public static let presets: [PrintLayout] = [.a4Single, .a4Duplex, .a3BookletA4, .a4BookletA5, .a3TwoUp]
}

public struct PrintOptions: Codable, Equatable, Sendable {
    public var marginsInMillimeters: Double
    public var showsPageNumbers: Bool
    public var rotatesBackSides: Bool

    public init(marginsInMillimeters: Double = 15, showsPageNumbers: Bool = false, rotatesBackSides: Bool = false) {
        self.marginsInMillimeters = marginsInMillimeters
        self.showsPageNumbers = showsPageNumbers
        self.rotatesBackSides = rotatesBackSides
    }
}
