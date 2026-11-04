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
        let orientation: PaperOrientation
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
    /// 2-up sheets sit two to a row; built once, since the tray reads it on every update.
    let rows: [Row]

    /// - Parameter blankPages: Logical pages added as blanks, which the tray names as blanks too.
    init(
        plan: ImpositionPlan, layout: PrintLayout, rotatesBackSides: Bool, sheetOrientations: [PaperOrientation] = [],
        blankPages: Set<Int> = []
    ) {
        self.layout = layout
        let sides = plan.sides.enumerated().map { index, side in
            Side(
                face: plan.isDuplex ? (side.isBack ? .back : .front) : .single, documentIndex: index,
                pages: side.slots.map { slot in slot.flatMap { blankPages.contains($0) ? nil : $0 + 1 } },
                // PDFComposer turns exactly these sides, so the labels must follow the drawing.
                isRotated: rotatesBackSides && side.isBack)
        }
        let perSheet = plan.isDuplex ? 2 : 1
        let groups = stride(from: 0, to: sides.count, by: perSheet).map {
            Array(sides[$0..<min($0 + perSheet, sides.count)])
        }
        let sheets = groups.enumerated().map { index, sides in
            let documentIndex = sides.first?.documentIndex ?? 0
            let orientation =
                sheetOrientations.indices.contains(documentIndex)
                ? sheetOrientations[documentIndex]
                : (layout.sheetSize.width > layout.sheetSize.height ? PaperOrientation.landscape : .portrait)
            return Sheet(
                index: index, position: Self.position(of: index, count: groups.count, layout: layout),
                sides: sides, orientation: orientation)
        }
        self.sheets = sheets
        let perRow = layout.kind == .twoUp ? 2 : 1
        rows = stride(from: 0, to: sheets.count, by: perRow).map {
            Row(sheets: Array(sheets[$0..<min($0 + perRow, sheets.count)]))
        }
    }

    var isBooklet: Bool { layout.kind == .booklet }

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

    /// The sheet heading above a sheet and the page captions below it.
    static let sheetChrome: CGFloat = 64

    /// At zoom 1 a sheet fits the width and, given `viewportHeight` (the height left below the instructions), the
    /// height too, so print mode opens with a whole sheet in view. With mixed orientations the taller portrait sheets
    /// decide the height.
    init(
        layout: PrintLayout, viewportWidth: CGFloat, viewportHeight: CGFloat = .infinity,
        mixedOrientations: Bool = false, zoom: CGFloat
    ) {
        let available = max(400, viewportWidth - 2 * Self.padding - 100)
        let pageWidth: CGFloat
        switch layout.kind {
        case .normal, .handout3:
            pageWidth =
                layout.duplex == .none ? min(600, available - 120) : min(480, (available - Self.sideSpacing) / 2)
        case .twoUp:
            pageWidth = min(max((available - Self.twoUpSpacing) / 4, 110), 300)
        case .booklet:
            pageWidth = min(max((available - Self.sideSpacing) / 4, 110), 300)
        }
        let zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let widthScale = pageWidth / (layout.kind == .handout3 ? layout.sheetSize.width : layout.logicalPageSize.width)
        let sheetHeight =
            mixedOrientations ? max(layout.sheetSize.width, layout.sheetSize.height) : layout.sheetSize.height
        let heightScale =
            viewportHeight.isFinite ? max(viewportHeight - Self.sheetChrome, 120) / sheetHeight : widthScale
        scale = min(widthScale, heightScale) * zoom
        sideSize = CGSize(width: layout.sheetSize.width * scale, height: layout.sheetSize.height * scale)
        rowWidth =
            switch layout.kind {
            case .handout3: sideSize.width
            case .normal: layout.duplex == .none ? sideSize.width : sideSize.width * 2 + Self.sideSpacing
            case .twoUp: sideSize.width * 2 + Self.twoUpSpacing
            case .booklet: sideSize.width * 2 + Self.sideSpacing
            }
    }

    var zoomPercent: Int { Int((scale * 100).rounded()) }
}

/// Print mode texts for an explicit language, like `DocumentViewModel.summaryText`, so tests can pin them.
enum PrintModeText {
    static func mixedNote(_ orientations: [PaperOrientation], language: String) -> String? {
        let portrait = orientations.filter { $0 == .portrait }.count
        let landscape = orientations.filter { $0 == .landscape }.count
        guard portrait > 0 && landscape > 0 else { return nil }
        return format("%1$lld portrait · %2$lld landscape", language: language, portrait, landscape)
    }

    static func sheetTitle(_ sheet: PrintTray.Sheet, language: String) -> String {
        format("Sheet %lld", language: language, sheet.number)
    }

    static func sheetSubtitle(_ sheet: PrintTray.Sheet, layout: PrintLayout, language: String) -> String {
        let paper = layout.sheet.shortName
        switch sheet.position {
        case .outermost: return format("%@ landscape · outermost", language: language, paper)
        case .innermost: return format("%@ landscape · innermost (center spread)", language: language, paper)
        case .only, .middle, .unstacked:
            let landscape = sheet.orientation == .landscape
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
        let paper = layout.sheet.shortName
        switch layout.kind {
        case .handout3:
            return format(
                "Prints **three pages on the left of %@ portrait**, single-sided, with ruled notes on the right.",
                language: language, paper)
        case .booklet:
            return format(
                "Print on **both sides of %1$@ landscape** (short-edge binding). Stack the sheets with sheet 1 outermost, fold them in the middle and staple twice along the fold to get the **%2$@ booklet**.",
                language: language, paper, (layout.sheet.halved ?? layout.sheet).shortName)
        case .twoUp:
            return format(
                layout.landscapeContent
                    ? "Prints **two pages stacked on %@ portrait**, single-sided. No folding."
                    : "Prints **two pages side by side on %@ landscape**, single-sided. No folding.",
                language: language, paper)
        case .normal:
            switch layout.duplex {
            case .none:
                return format(
                    layout.landscapeContent
                        ? "Prints **one page per %@ landscape sheet**, single-sided."
                        : "Prints **one page per %@ portrait sheet**, single-sided.",
                    language: language, paper)
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
        case .handout3:
            return string(
                pageCount % 3 == 0
                    ? "Three pages on the left · notes on the right"
                    : "Three pages on the left · notes on the right · unused slots on the last sheet are blank",
                language: language)
        case .booklet:
            let booklet = (layout.sheet.halved ?? layout.sheet).shortName
            let blanks = (pageCount + 3) / 4 * 4 - pageCount
            switch blanks {
            case 0: return format("%@ booklet when folded in the middle · no blank pages", language: language, booklet)
            case 1:
                return format(
                    "%@ booklet when folded in the middle · 1 blank page (the back cover)", language: language, booklet)
            default:
                return format(
                    "%1$@ booklet when folded in the middle · %2$lld blank pages (the last %3$lld)",
                    language: language, booklet, blanks, blanks)
            }
        case .twoUp:
            if layout.hasStackedSlots {
                return string(
                    pageCount % 2 == 1
                        ? "Two pages stacked, no folding · the last bottom half is blank"
                        : "Two pages stacked, no folding", language: language)
            }
            return string(
                pageCount % 2 == 1
                    ? "Two pages side by side, no folding · the last right half is blank"
                    : "Two pages side by side, no folding", language: language)
        case .normal:
            switch layout.duplex {
            case .none:
                return format(
                    layout.landscapeContent ? "%@ landscape · one page per sheet" : "%@ portrait · one page per sheet",
                    language: language, layout.sheet.shortName)
            case .longEdge, .shortEdge:
                return string(
                    pageCount % 2 == 1
                        ? "The back of the last sheet is blank" : "Back sides turn like the pages of a book",
                    language: language)
            }
        }
    }

    static func stackedCaption(_ pages: [Int?], language: String) -> String {
        guard let first = pages.first ?? nil else { return string("Blank", language: language) }
        if let last = pages.last ?? nil, pages.count > 1 {
            return format("Pages %1$lld–%2$lld", language: language, first, last)
        }
        return format("Page %lld · bottom half blank", language: language, first)
    }

    static func handoutCaption(_ pages: [Int?], language: String) -> String {
        let numbers = pages.compactMap { $0 }
        guard let first = numbers.first, let last = numbers.last else { return string("Blank", language: language) }
        return first == last
            ? format("Page %lld", language: language, first)
            : format("Pages %1$lld–%2$lld", language: language, first, last)
    }

    /// What a layout card makes, for example "A5 Booklet". A booklet is named by what comes out, which is half its
    /// paper, so that the reader who wants an A4 booklet does not pick A4 paper.
    static func cardTitle(_ layout: PrintLayout, language: String) -> String {
        let paper = layout.sheet.shortName
        switch layout.kind {
        case .handout3: return string("3 Pages + Notes Column", language: language)
        case .booklet: return format("%@ Booklet", language: language, (layout.sheet.halved ?? layout.sheet).shortName)
        case .twoUp: return string("2 Pages Side by Side", language: language)
        case .normal: return format(layout.duplex == .none ? "%@ Single" : "%@ Duplex", language: language, paper)
        }
    }

    /// The paper of a card whose title names something else.
    static func cardPaper(_ layout: PrintLayout, language: String) -> String? {
        layout.kind == .normal ? nil : format("Prints on %@", language: language, layout.sheet.shortName)
    }

    /// The printer's rotation is not on the sheets' choices, so it is told under the summary.
    static func options(_ options: PrintOptions, layout: PrintLayout, language: String) -> String? {
        options.rotatesBackSides && layout.duplex != .none
            ? string("Back sides rotated 180°", language: language) : nil
    }

    /// What the finish added to the pages of a text, or nil.
    static func additions(contents: Int, blanks: Int, language: String) -> String? {
        switch (contents > 0, blanks > 0) {
        case (false, false): nil
        case (true, false): format("Added: contents %lld", language: language, contents)
        case (false, true): format("Added: blank pages %lld", language: language, blanks)
        case (true, true):
            format("Added: contents %1$lld, blank pages %2$lld", language: language, contents, blanks)
        }
    }

    static func pageCount(_ count: Int, language: String) -> String {
        format("%lld pages", language: language, count)
    }

    /// The pages of the tray, and how many of them are the document's and how many notes.
    static func pageCount(_ count: Int, notes: Int, language: String) -> String {
        guard notes > 0 else { return pageCount(count, language: language) }
        return format(
            "%1$lld pages (body %2$lld + notes %3$lld)", language: language, count, count - notes, notes)
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
