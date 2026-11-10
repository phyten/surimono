import CoreGraphics
import Foundation

public enum PaperSize: String, CaseIterable, Codable, Sendable {
    case a3, a4, a5, b4, b5, b6, letter, tabloid, halfLetter

    public var size: CGSize {
        if self == .letter { return CGSize(width: 612, height: 792) }
        if self == .tabloid { return CGSize(width: 792, height: 1224) }
        if self == .halfLetter { return CGSize(width: 396, height: 612) }
        let millimeters: (Double, Double) =
            switch self {
            case .a3: (297, 420)
            case .a4: (210, 297)
            case .a5: (148, 210)
            case .b4: (257, 364)
            case .b5: (182, 257)
            case .b6: (128, 182)
            case .letter: (215.9, 279.4)
            case .tabloid: (279.4, 431.8)
            case .halfLetter: (139.7, 215.9)
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
        case .b6: "B6 (JIS)"
        case .letter: "Letter"
        case .tabloid: "Tabloid"
        case .halfLetter: "Half Letter"
        }
    }

    /// The name on a layout card, where the series switch already says which B sizes are meant.
    public var shortName: String {
        switch self {
        case .b4: "B4"
        case .b5: "B5"
        case .b6: "B6"
        default: displayName
        }
    }

    public var halved: PaperSize? {
        switch self {
        case .a3: .a4
        case .a4: .a5
        case .b4: .b5
        case .b5: .b6
        case .tabloid: .letter
        case .letter: .halfLetter
        default: nil
        }
    }

    public var series: PaperSeries {
        switch self {
        case .b4, .b5, .b6: .b
        case .letter, .tabloid, .halfLetter: .letter
        default: .a
        }
    }
}

/// The B sizes use JIS dimensions so existing Japanese documents keep their paper.
public enum PaperSeries: String, CaseIterable, Codable, Sendable {
    case a, b, letter

    public static func initial(locale: Locale, defaultPaperSize: CGSize? = nil) -> PaperSeries {
        if let size = defaultPaperSize,
            abs(min(size.width, size.height) - 612) < 1 && abs(max(size.width, size.height) - 792) < 1
        {
            return .letter
        }
        return locale.measurementSystem == .us ? .letter : .a
    }
}

public enum BookletBinding: String, CaseIterable, Codable, Sendable {
    case left, right
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
    case normal, twoUp, booklet, handout3, fourUp
}

public struct PrintLayout: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: LayoutKind
    public let sheet: PaperSize
    public let duplex: DuplexMode
    public private(set) var landscapeContent = false
    public private(set) var bookletBinding: BookletBinding = .left

    public enum ValidationError: Error, Sendable {
        case missingHalfSize
        case twoUpMustBeSingleSided
        case bookletMustUseShortEdge
        case handoutMustBeSingleSided
        case fourUpMustBeSingleSided
    }

    public init(id: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) throws {
        if (kind == .twoUp || kind == .booklet) && sheet.halved == nil { throw ValidationError.missingHalfSize }
        if kind == .twoUp && duplex != .none { throw ValidationError.twoUpMustBeSingleSided }
        if kind == .booklet && duplex != .shortEdge { throw ValidationError.bookletMustUseShortEdge }
        if kind == .handout3 && duplex != .none { throw ValidationError.handoutMustBeSingleSided }
        if kind == .fourUp && duplex != .none { throw ValidationError.fourUpMustBeSingleSided }
        self.init(validatedID: id, kind: kind, sheet: sheet, duplex: duplex)
    }

    private init(validatedID: String, kind: LayoutKind, sheet: PaperSize, duplex: DuplexMode) {
        id = validatedID
        self.kind = kind
        self.sheet = sheet
        self.duplex = duplex
    }

    private enum CodingKeys: String, CodingKey { case id, kind, sheet, duplex, landscapeContent, bookletBinding }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id), kind: values.decode(LayoutKind.self, forKey: .kind),
            sheet: values.decode(PaperSize.self, forKey: .sheet),
            duplex: values.decode(DuplexMode.self, forKey: .duplex))
        landscapeContent =
            try !hasFixedOrientation && (values.decodeIfPresent(Bool.self, forKey: .landscapeContent) ?? false)
        bookletBinding = try values.decodeIfPresent(BookletBinding.self, forKey: .bookletBinding) ?? .left
    }

    public var sheetSize: CGSize {
        if kind == .handout3 || kind == .fourUp { return sheet.size }
        let landscapeSheet = kind == .normal ? landscapeContent : !landscapeContent
        return landscapeSheet ? CGSize(width: sheet.size.height, height: sheet.size.width) : sheet.size
    }

    public var sentDuplex: DuplexMode {
        duplex == .longEdge && sheetSize.width > sheetSize.height ? .shortEdge : duplex
    }

    public var logicalPageSize: CGSize { logicalPageSize(options: PrintOptions()) }

    public func logicalPageSize(options: PrintOptions) -> CGSize {
        if kind == .fourUp { return CGSize(width: sheet.size.width / 2, height: sheet.size.height / 2) }
        if kind == .handout3 {
            let rect = slotRect(at: 0, options: options)
            return CGSize(width: rect.width * sheetSize.width, height: rect.height * sheetSize.height)
        }
        let size = kind == .normal ? sheet.size : (sheet.halved ?? sheet).size
        return landscapeContent ? CGSize(width: size.height, height: size.width) : size
    }

    public func oriented(_ landscape: Bool) -> PrintLayout {
        var result = self
        result.landscapeContent = !hasFixedOrientation && landscape
        return result
    }

    public var hasFixedOrientation: Bool { kind == .booklet || kind == .handout3 || kind == .fourUp }

    public func bound(_ binding: BookletBinding) -> PrintLayout {
        var result = self
        result.bookletBinding = kind == .booklet ? binding : .left
        return result
    }

    public var isRightBound: Bool { kind == .booklet && bookletBinding == .right }

    public func swapsSides(onPage index: Int) -> Bool { (index % 2 == 1) != isRightBound }

    public var hasStackedSlots: Bool { kind == .handout3 || (kind == .twoUp && landscapeContent) }

    /// A unit rectangle measured from the top left, shared by the sheet preview and PDF composition.
    public func slotRect(at index: Int, options: PrintOptions = PrintOptions()) -> CGRect {
        guard (0..<pagesPerSide).contains(index) else { return .zero }
        if kind == .handout3 {
            let size = CGSize(width: sheetSize.width * 25.4 / 72, height: sheetSize.height * 25.4 / 72)
            let margins = options.margins
            let gap = Self.handoutGapInMillimeters
            let width = (size.width - margins.left - margins.right - gap) * 0.64
            let height = (size.height - margins.top - margins.bottom - 2 * gap) / 3
            return CGRect(
                x: margins.left / size.width, y: (margins.top + CGFloat(index) * (height + gap)) / size.height,
                width: width / size.width, height: height / size.height)
        }
        if kind == .fourUp {
            return CGRect(x: CGFloat(index % 2) / 2, y: CGFloat(index / 2) / 2, width: 0.5, height: 0.5)
        }
        if hasStackedSlots {
            return CGRect(x: 0, y: CGFloat(index) / 2, width: 1, height: 0.5)
        }
        return CGRect(x: CGFloat(index) / CGFloat(pagesPerSide), y: 0, width: 1 / CGFloat(pagesPerSide), height: 1)
    }

    public func memoRect(options: PrintOptions = PrintOptions()) -> CGRect? {
        guard kind == .handout3 else { return nil }
        let size = CGSize(width: sheetSize.width * 25.4 / 72, height: sheetSize.height * 25.4 / 72)
        let margins = options.margins
        let width = (size.width - margins.left - margins.right - Self.handoutGapInMillimeters) * 0.36
        return CGRect(
            x: (size.width - margins.right - width) / size.width, y: margins.top / size.height,
            width: width / size.width, height: (size.height - margins.top - margins.bottom) / size.height)
    }

    /// The space between the slots of the 3-up handout.
    public static let handoutGapInMillimeters = 8.0

    // Handout margins surround the sheet, not each of its already inset logical pages.
    public func logicalMargins(options: PrintOptions) -> PageMargins {
        kind == .handout3 ? .zero : options.margins
    }

    /// Whether the sheets are turned like the pages of a book, which is what gives a page a left or right hand.
    public var hasFacingPages: Bool { duplex != .none }

    /// Whether the even pages take the left and right margins the other way round.
    public func mirrorsMargins(options: PrintOptions) -> Bool { options.mirrorsMargins && hasFacingPages }

    public var pagesPerSide: Int { kind == .fourUp ? 4 : kind == .handout3 ? 3 : kind == .normal ? 1 : 2 }

    public func displayName(language: String = "en") -> String {
        let terms: [String: [String]] = [
            "en": ["Single-sided", "Duplex", "3-up + Notes", "2-up", "Booklet", "4 Pages on One Sheet"],
            "ja": ["片面", "両面", "3枚＋メモ", "2 ページを 1 枚に", "中綴じ", "4 ページを 1 枚に"],
            "zh-Hans": ["单面", "双面", "每页3张＋笔记", "每页2张", "小册子", "每页4张"],
            "zh-Hant": ["單面", "雙面", "每頁3張＋筆記", "每頁2張", "小冊子", "每頁4張"],
            "ko": ["단면", "양면", "3쪽 + 메모", "2쪽 모아찍기", "소책자", "4쪽 모아찍기"],
            "fr": ["Recto", "Recto verso", "3 pages + notes", "2 pages par feuille", "Livret", "4 pages par feuille"],
            "de": [
                "Einseitig", "Beidseitig", "3 Seiten + Notizen", "2 Seiten pro Blatt", "Broschüre",
                "4 Seiten pro Blatt",
            ],
            "es": [
                "Una cara", "Doble cara", "3 páginas + notas", "2 páginas por hoja", "Folleto", "4 páginas por hoja",
            ],
        ]
        let index: Int
        switch kind {
        case .normal: index = duplex == .none ? 0 : 1
        case .handout3: index = 2
        case .twoUp: index = 3
        case .booklet: index = 4
        case .fourUp: index = 5
        }
        let names = terms.mapValues { $0[index] }
        let title = UILanguage.name(names, language: language, english: names["en"] ?? "")
        guard kind == .booklet else { return "\(sheet.displayName) \(title)" }
        let made = (sheet.halved ?? sheet).displayName
        // Japanese names a booklet by what comes out, as its card does, and adds the paper and the binding.
        if title == names["ja"] { return "\(made) 冊子・\(sheet.displayName) \(title)" }
        return "\(sheet.displayName) \(title) → \(made)"
    }

    public static let a4Single = PrintLayout(validatedID: "a4Single", kind: .normal, sheet: .a4, duplex: .none)
    public static let a4Duplex = PrintLayout(validatedID: "a4Duplex", kind: .normal, sheet: .a4, duplex: .longEdge)
    public static let a3BookletA4 = PrintLayout(
        validatedID: "a3BookletA4", kind: .booklet, sheet: .a3, duplex: .shortEdge)
    public static let a4BookletA5 = PrintLayout(
        validatedID: "a4BookletA5", kind: .booklet, sheet: .a4, duplex: .shortEdge)
    public static let a3TwoUp = PrintLayout(validatedID: "a3TwoUp", kind: .twoUp, sheet: .a3, duplex: .none)
    public static let a4Handout3 = PrintLayout(validatedID: "a4Handout3", kind: .handout3, sheet: .a4, duplex: .none)
    public static let b5Single = PrintLayout(validatedID: "b5Single", kind: .normal, sheet: .b5, duplex: .none)
    public static let b5Duplex = PrintLayout(validatedID: "b5Duplex", kind: .normal, sheet: .b5, duplex: .longEdge)
    public static let b4BookletB5 = PrintLayout(
        validatedID: "b4BookletB5", kind: .booklet, sheet: .b4, duplex: .shortEdge)
    public static let b5BookletB6 = PrintLayout(
        validatedID: "b5BookletB6", kind: .booklet, sheet: .b5, duplex: .shortEdge)
    public static let b4TwoUp = PrintLayout(validatedID: "b4TwoUp", kind: .twoUp, sheet: .b4, duplex: .none)
    public static let b5Handout3 = PrintLayout(validatedID: "b5Handout3", kind: .handout3, sheet: .b5, duplex: .none)
    public static let letterSingle = PrintLayout(
        validatedID: "letterSingle", kind: .normal, sheet: .letter, duplex: .none)
    public static let letterDuplex = PrintLayout(
        validatedID: "letterDuplex", kind: .normal, sheet: .letter, duplex: .longEdge)
    public static let tabloidBookletLetter = PrintLayout(
        validatedID: "tabloidBookletLetter", kind: .booklet, sheet: .tabloid, duplex: .shortEdge)
    public static let letterBookletHalfLetter = PrintLayout(
        validatedID: "letterBookletHalfLetter", kind: .booklet, sheet: .letter, duplex: .shortEdge)
    public static let tabloidTwoUp = PrintLayout(
        validatedID: "tabloidTwoUp", kind: .twoUp, sheet: .tabloid, duplex: .none)
    public static let letterHandout3 = PrintLayout(
        validatedID: "letterHandout3", kind: .handout3, sheet: .letter, duplex: .none)
    public static let a4TwoUp = PrintLayout(validatedID: "a4TwoUp", kind: .twoUp, sheet: .a4, duplex: .none)
    public static let b5TwoUp = PrintLayout(validatedID: "b5TwoUp", kind: .twoUp, sheet: .b5, duplex: .none)
    public static let letterTwoUp = PrintLayout(validatedID: "letterTwoUp", kind: .twoUp, sheet: .letter, duplex: .none)
    public static let a4FourUp = PrintLayout(validatedID: "a4FourUp", kind: .fourUp, sheet: .a4, duplex: .none)
    public static let b5FourUp = PrintLayout(validatedID: "b5FourUp", kind: .fourUp, sheet: .b5, duplex: .none)
    public static let letterFourUp = PrintLayout(
        validatedID: "letterFourUp", kind: .fourUp, sheet: .letter, duplex: .none)
    public static let presets: [PrintLayout] = PaperSeries.allCases.flatMap { presets(in: $0) + compactPresets(in: $0) }

    public static func presets(in series: PaperSeries) -> [PrintLayout] {
        switch series {
        case .a: [.a4Single, .a4Duplex, .a3BookletA4, .a4BookletA5, .a3TwoUp, .a4Handout3]
        case .b: [.b5Single, .b5Duplex, .b4BookletB5, .b5BookletB6, .b4TwoUp, .b5Handout3]
        case .letter:
            [
                .letterSingle, .letterDuplex, .tabloidBookletLetter, .letterBookletHalfLetter, .tabloidTwoUp,
                .letterHandout3,
            ]
        }
    }

    public static func compactPresets(in series: PaperSeries) -> [PrintLayout] {
        switch series {
        case .a: [.a4TwoUp, .a4FourUp]
        case .b: [.b5TwoUp, .b5FourUp]
        case .letter: [.letterTwoUp, .letterFourUp]
        }
    }

    public var series: PaperSeries { sheet.series }

    /// The layout that prints the same way on the other series; a layout with no counterpart starts from the first.
    public func counterpart(in series: PaperSeries) -> PrintLayout {
        guard series != self.series else { return self }
        let index =
            (Self.presets(in: self.series) + Self.compactPresets(in: self.series)).firstIndex { $0.id == id } ?? 0
        let others = Self.presets(in: series) + Self.compactPresets(in: series)
        return (others.indices.contains(index) ? others[index] : others[0]).bound(bookletBinding)
    }
}

/// The four margins of a page, in millimeters.
public struct PageMargins: Codable, Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static func uniform(_ millimeters: Double) -> PageMargins {
        PageMargins(top: millimeters, left: millimeters, bottom: millimeters, right: millimeters)
    }

    public static let zero = uniform(0)

    public var isValid: Bool { [top, left, bottom, right].allSatisfy { $0.isFinite && $0 >= 0 } }

    /// The one value of all four sides, or nil when they differ.
    public var uniformValue: Double? { top == left && top == bottom && top == right ? top : nil }

    public var smallest: Double { min(top, left, bottom, right) }

    public var mirrored: PageMargins { PageMargins(top: top, left: right, bottom: bottom, right: left) }
}

public struct PrintOptions: Codable, Equatable, Sendable {
    public var margins: PageMargins
    /// The tray changes the four margins together.
    public var linksMargins: Bool
    /// On duplex sheets and booklets, `margins.left` is the side of the binding and `margins.right` the outer side.
    public var mirrorsMargins: Bool
    public var furniture: PageFurniture
    public var rotatesBackSides: Bool

    /// All four margins as one value. Reading a page with uneven margins gives its top margin.
    public var marginsInMillimeters: Double {
        get { margins.top }
        set { margins = .uniform(newValue) }
    }

    /// Whether the pages carry a header or footer at all. Records used to keep this switch; `furniture` holds it now.
    public var showsPageNumbers: Bool { furniture.preset != .none }

    public init(marginsInMillimeters: Double = 15, showsPageNumbers: Bool = false, rotatesBackSides: Bool = false) {
        margins = .uniform(marginsInMillimeters)
        linksMargins = true
        mirrorsMargins = false
        furniture = showsPageNumbers ? .pageNumber : PageFurniture()
        self.rotatesBackSides = rotatesBackSides
    }

    private enum CodingKeys: String, CodingKey {
        case margins, linksMargins, mirrorsMargins, furniture, rotatesBackSides
        case marginsInMillimeters, showsPageNumbers
    }

    /// Reads records from before the four margins and the header and footer, which kept one margin and a switch.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let margin = try? values.decodeIfPresent(Double.self, forKey: .marginsInMillimeters)
        margins = (try? values.decodeIfPresent(PageMargins.self, forKey: .margins)) ?? .uniform(margin ?? 15)
        linksMargins =
            (try? values.decodeIfPresent(Bool.self, forKey: .linksMargins)) ?? (margins.uniformValue != nil)
        mirrorsMargins = (try? values.decodeIfPresent(Bool.self, forKey: .mirrorsMargins)) ?? false
        let numbers = (try? values.decodeIfPresent(Bool.self, forKey: .showsPageNumbers)) ?? false
        furniture =
            (try? values.decodeIfPresent(PageFurniture.self, forKey: .furniture))
            ?? (numbers ? .pageNumber : PageFurniture())
        rotatesBackSides = (try? values.decodeIfPresent(Bool.self, forKey: .rotatesBackSides)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(margins, forKey: .margins)
        try values.encode(linksMargins, forKey: .linksMargins)
        try values.encode(mirrorsMargins, forKey: .mirrorsMargins)
        try values.encode(furniture, forKey: .furniture)
        // Rotation belongs to the printer; document records clear it and must not carry the field.
        if rotatesBackSides { try values.encode(rotatesBackSides, forKey: .rotatesBackSides) }
    }
}
