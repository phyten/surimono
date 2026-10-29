import CoreGraphics
import Foundation
import SurimonoCore

/// The physical sheets of an imposition plan, grouped the way they come out of the printer.
struct PrintTray: Equatable {
    enum Face: Equatable { case single, front, back }

    /// Where a booklet sheet sits in the folded stack. Other layouts have no stack.
    enum Position: Equatable { case only, outermost, middle, innermost, unstacked }

    struct Side: Equatable {
        let face: Face
        /// The page of `RenderResult.sheetDocument` that shows this side.
        let documentIndex: Int
        /// 1-based logical page numbers from left to right as printed; nil marks a blank half.
        let pages: [Int?]
        /// The side is printed upside down ("Rotate Back Sides 180°").
        let isRotated: Bool

        /// Page numbers from left to right as they appear on the drawn side.
        var visiblePages: [Int?] { isRotated ? pages.reversed() : pages }
    }

    struct Sheet: Equatable, Identifiable {
        let index: Int
        let position: Position
        let sides: [Side]
        var id: Int { index }
        var number: Int { index + 1 }
    }

    /// A line of the tray: 2-up sheets sit two to a row, other layouts one sheet per row.
    struct Row: Equatable, Identifiable {
        let sheets: [Sheet]
        var id: Int { sheets.first?.index ?? 0 }
    }

    let layout: PrintLayout
    let sheets: [Sheet]

    init(plan: ImpositionPlan, layout: PrintLayout, rotatesBackSides: Bool) {
        self.layout = layout
        let sides = plan.sides.enumerated().map { index, side in
            Side(
                face: plan.isDuplex ? (side.isBack ? .back : .front) : .single, documentIndex: index,
                pages: side.slots.map { $0.map { $0 + 1 } },
                // PDFComposer turns exactly these sides, so the labels must follow the drawing.
                isRotated: rotatesBackSides && side.isBack)
        }
        let perSheet = plan.isDuplex ? 2 : 1
        let groups = stride(from: 0, to: sides.count, by: perSheet).map {
            Array(sides[$0..<min($0 + perSheet, sides.count)])
        }
        sheets = groups.enumerated().map { index, sides in
            Sheet(index: index, position: Self.position(of: index, count: groups.count, layout: layout), sides: sides)
        }
    }

    var isBooklet: Bool { layout.kind == .booklet }

    var rows: [Row] {
        let perRow = layout.kind == .twoUp ? 2 : 1
        return stride(from: 0, to: sheets.count, by: perRow).map {
            Row(sheets: Array(sheets[$0..<min($0 + perRow, sheets.count)]))
        }
    }

    static func position(of index: Int, count: Int, layout: PrintLayout) -> Position {
        guard layout.kind == .booklet else { return .unstacked }
        if count == 1 { return .only }
        if index == 0 { return .outermost }
        if index == count - 1 { return .innermost }
        return .middle
    }
}

/// Sizes on the tray. The base size fits the window width; the zoom multiplies it.
struct TrayMetrics: Equatable {
    static let padding: CGFloat = 44
    static let sideSpacing: CGFloat = 28
    static let twoUpSpacing: CGFloat = 36
    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.5

    /// Display points per PDF point.
    let scale: CGFloat
    let sideSize: CGSize
    let rowWidth: CGFloat

    init(layout: PrintLayout, viewportWidth: CGFloat, zoom: CGFloat) {
        let available = max(400, viewportWidth - 2 * Self.padding - 100)
        let pageWidth: CGFloat
        switch layout.kind {
        case .normal:
            pageWidth =
                layout.duplex == .none ? min(600, available - 120) : min(480, (available - Self.sideSpacing) / 2)
        case .twoUp:
            pageWidth = min(max((available - Self.twoUpSpacing) / 4, 110), 300)
        case .booklet:
            pageWidth = min(max((available - Self.sideSpacing) / 4, 110), 300)
        }
        let zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        scale = pageWidth * zoom / layout.logicalPageSize.width
        sideSize = CGSize(width: layout.sheetSize.width * scale, height: layout.sheetSize.height * scale)
        rowWidth =
            switch layout.kind {
            case .normal: layout.duplex == .none ? sideSize.width : sideSize.width * 2 + Self.sideSpacing
            case .twoUp: sideSize.width * 2 + Self.twoUpSpacing
            case .booklet: sideSize.width * 2 + Self.sideSpacing
            }
    }

    var zoomPercent: Int { Int((scale * 100).rounded()) }
}

/// Print mode texts for an explicit language, like `DocumentViewModel.summaryText`, so tests can pin them.
enum PrintModeText {
    static func sheetTitle(_ sheet: PrintTray.Sheet, language: String) -> String {
        format("Sheet %lld", language: language, sheet.number)
    }

    static func sheetSubtitle(_ sheet: PrintTray.Sheet, layout: PrintLayout, language: String) -> String {
        let paper = layout.sheet.displayName
        switch sheet.position {
        case .outermost: return format("%@ landscape · outermost", language: language, paper)
        case .innermost: return format("%@ landscape · innermost (center spread)", language: language, paper)
        case .only, .middle, .unstacked:
            let landscape = layout.sheetSize.width > layout.sheetSize.height
            return format(landscape ? "%@ landscape" : "%@ portrait", language: language, paper)
        }
    }

    static func faceLabel(_ side: PrintTray.Side, language: String) -> String? {
        switch side.face {
        case .single: nil
        case .front: string("Front", language: language)
        case .back: string(side.isRotated ? "Back 180°" : "Back", language: language)
        }
    }

    /// How the sheets are printed and finished, with Markdown emphasis.
    static func instructions(_ layout: PrintLayout, language: String) -> String {
        let paper = layout.sheet.displayName
        switch layout.kind {
        case .booklet:
            return format(
                "Print on **both sides of %1$@ landscape** (short-edge binding). Stack the sheets with sheet 1 outermost, fold them in the middle and staple twice along the fold to get the **%2$@ booklet**.",
                language: language, paper, (layout.sheet.halved ?? layout.sheet).displayName)
        case .twoUp:
            return format(
                "Prints **two pages side by side on %@ landscape**, single-sided. No folding.", language: language,
                paper)
        case .normal:
            switch layout.duplex {
            case .none:
                return format("Prints **one page per %@ portrait sheet**, single-sided.", language: language, paper)
            case .longEdge:
                return format(
                    "Prints on **both sides of %@** (long-edge binding). Back sides turn like the pages of a book.",
                    language: language, paper)
            case .shortEdge:
                return format("Prints on **both sides of %@** (short-edge binding).", language: language, paper)
            }
        }
    }

    /// The second line under the summary: what to do with the sheets and where blanks fall.
    static func note(_ layout: PrintLayout, pageCount: Int, language: String) -> String {
        switch layout.kind {
        case .booklet:
            let booklet = (layout.sheet.halved ?? layout.sheet).displayName
            let blanks = (pageCount + 3) / 4 * 4 - pageCount
            return blanks == 0
                ? format("%@ booklet when folded in the middle · no blank pages", language: language, booklet)
                : format(
                    "%1$@ booklet when folded in the middle · blank pages before the back cover: %2$lld",
                    language: language, booklet, blanks)
        case .twoUp:
            return string(
                pageCount % 2 == 1
                    ? "Two pages side by side, no folding · the last right half is blank"
                    : "Two pages side by side, no folding", language: language)
        case .normal:
            switch layout.duplex {
            case .none:
                return format("%@ portrait · one page per sheet", language: language, layout.sheet.displayName)
            case .longEdge, .shortEdge:
                return string(
                    pageCount % 2 == 1
                        ? "The back of the last sheet is blank" : "Back sides turn like the pages of a book",
                    language: language)
            }
        }
    }

    /// The short name on a layout card, for example "A3 Booklet".
    static func cardTitle(_ layout: PrintLayout, language: String) -> String {
        let paper = layout.sheet.displayName
        switch layout.kind {
        case .booklet: return format("%@ Booklet", language: language, paper)
        case .twoUp: return format("%@ 2-up", language: language, paper)
        case .normal: return format(layout.duplex == .none ? "%@ Single" : "%@ Duplex", language: language, paper)
        }
    }

    /// Active options worth a reminder under the summary, or nil.
    static func options(_ options: PrintOptions, layout: PrintLayout, language: String) -> String? {
        var parts: [String] = []
        if options.showsPageNumbers { parts.append(string("Page numbers", language: language)) }
        if options.rotatesBackSides && layout.duplex != .none {
            parts.append(string("Back sides rotated 180°", language: language))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { format("%@ · %@", language: language, $0, $1) }
    }

    static func pageCount(_ count: Int, language: String) -> String {
        format("%lld pages", language: language, count)
    }

    static func string(_ key: String, language: String) -> String {
        bundle(language).localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, language: String, _ arguments: any CVarArg...) -> String {
        String(format: string(key, language: language), locale: Locale(identifier: language), arguments: arguments)
    }

    private static func bundle(_ language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
