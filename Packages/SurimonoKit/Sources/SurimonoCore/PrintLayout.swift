import CoreGraphics
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

public enum PaperOrientation: String, CaseIterable, Codable, Sendable {
    case auto, portrait, landscape

    public func isLandscape(pageSizes: [CGSize]) -> Bool {
        switch self {
        case .portrait: return false
        case .landscape: return true
        case .auto:
            let count = pageSizes.filter { $0.width > $0.height }.count
            if count * 2 == pageSizes.count {
                return pageSizes.first.map { $0.width > $0.height } ?? false
            }
            return count * 2 > pageSizes.count
        }
    }
}

public enum DuplexMode: String, Codable, Sendable {
    case none, longEdge, shortEdge
}

public enum LayoutKind: String, Codable, Sendable {
    case normal, twoUp, booklet, handout3
}

public struct PrintLayout: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: LayoutKind
    public let sheet: PaperSize
    public let duplex: DuplexMode
    public private(set) var landscapeContent = false

    public enum ValidationError: Error, Sendable {
        case missingHalfSize
        case twoUpMustBeSingleSided
        case bookletMustUseShortEdge
        case handoutMustBeSingleSided
    }

    public init(id: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) throws {
        if (kind == .twoUp || kind == .booklet) && sheet.halved == nil { throw ValidationError.missingHalfSize }
        if kind == .twoUp && duplex != .none { throw ValidationError.twoUpMustBeSingleSided }
        if kind == .booklet && duplex != .shortEdge { throw ValidationError.bookletMustUseShortEdge }
        if kind == .handout3 && duplex != .none { throw ValidationError.handoutMustBeSingleSided }
        self.init(validatedID: id, kind: kind, sheet: sheet, duplex: duplex)
    }

    private init(validatedID: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) {
        id = validatedID
        self.kind = kind
        self.sheet = sheet
        self.duplex = duplex
    }

    private enum CodingKeys: String, CodingKey { case id, kind, sheet, duplex, landscapeContent }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id), kind: values.decode(LayoutKind.self, forKey: .kind),
            sheet: values.decode(PaperSize.self, forKey: .sheet),
            duplex: values.decode(DuplexMode.self, forKey: .duplex))
        landscapeContent =
            try kind != .booklet && (values.decodeIfPresent(Bool.self, forKey: .landscapeContent) ?? false)
    }

    public var sheetSize: CGSize {
        if kind == .handout3 { return sheet.size }
        let landscapeSheet = kind == .normal ? landscapeContent : !landscapeContent
        return landscapeSheet ? CGSize(width: sheet.size.height, height: sheet.size.width) : sheet.size
    }

    public var logicalPageSize: CGSize { logicalPageSize(options: PrintOptions()) }

    public func logicalPageSize(options: PrintOptions) -> CGSize {
        if kind == .handout3 {
            let rect = slotRect(at: 0, options: options)
            return CGSize(width: rect.width * sheetSize.width, height: rect.height * sheetSize.height)
        }
        let size = kind == .normal ? sheet.size : (sheet.halved ?? sheet).size
        return landscapeContent ? CGSize(width: size.height, height: size.width) : size
    }

    public func oriented(_ landscape: Bool) -> PrintLayout {
        var result = self
        result.landscapeContent = kind != .booklet && landscape
        return result
    }

    public var hasStackedSlots: Bool { kind == .handout3 || (kind == .twoUp && landscapeContent) }

    /// A unit rectangle measured from the top left, shared by the sheet preview and PDF composition.
    public func slotRect(at index: Int, options: PrintOptions = PrintOptions()) -> CGRect {
        guard (0..<pagesPerSide).contains(index) else { return .zero }
        if kind == .handout3 {
            let size = CGSize(width: sheetSize.width * 25.4 / 72, height: sheetSize.height * 25.4 / 72)
            let margin = options.marginsInMillimeters
            let gap = 8.0
            let width = (size.width - 2 * margin - gap) * 0.64
            let height = (size.height - 2 * margin - 2 * gap) / 3
            return CGRect(
                x: margin / size.width, y: (margin + CGFloat(index) * (height + gap)) / size.height,
                width: width / size.width, height: height / size.height)
        }
        if hasStackedSlots {
            return CGRect(x: 0, y: CGFloat(index) / 2, width: 1, height: 0.5)
        }
        return CGRect(x: CGFloat(index) / CGFloat(pagesPerSide), y: 0, width: 1 / CGFloat(pagesPerSide), height: 1)
    }

    public func memoRect(options: PrintOptions = PrintOptions()) -> CGRect? {
        guard kind == .handout3 else { return nil }
        let size = CGSize(width: sheetSize.width * 25.4 / 72, height: sheetSize.height * 25.4 / 72)
        let margin = options.marginsInMillimeters
        let gap = 8.0
        let width = (size.width - 2 * margin - gap) * 0.36
        return CGRect(
            x: (size.width - margin - width) / size.width, y: margin / size.height,
            width: width / size.width, height: (size.height - 2 * margin) / size.height)
    }

    // Handout margins surround the sheet, not each of its already inset logical pages.
    public func logicalMarginsInMillimeters(options: PrintOptions) -> Double {
        kind == .handout3 ? 0 : options.marginsInMillimeters
    }

    public var pagesPerSide: Int { kind == .handout3 ? 3 : kind == .normal ? 1 : 2 }

    public func displayName(language: String = "en") -> String {
        let japanese = language.lowercased().hasPrefix("ja")
        switch kind {
        case .normal:
            return "\(sheet.displayName) "
                + (duplex == .none ? (japanese ? "片面" : "Single-sided") : (japanese ? "両面" : "Duplex"))
        case .handout3:
            return "\(sheet.displayName) " + (japanese ? "3枚＋メモ" : "3-up + Notes")
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
    public static let a4Handout3 = PrintLayout(validatedID: "a4Handout3", kind: .handout3, sheet: .a4, duplex: .none)
    public static let presets: [PrintLayout] = [
        .a4Single, .a4Duplex, .a3BookletA4, .a4BookletA5, .a3TwoUp, .a4Handout3,
    ]
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
