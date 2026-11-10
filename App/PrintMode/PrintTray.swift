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
    /// The page numbers that are note pages.
    let notePages: Set<Int>

    /// - Parameter blankPages: Logical pages added as blanks, which the tray names as blanks too.
    init(
        plan: ImpositionPlan, layout: PrintLayout, rotatesBackSides: Bool, sheetOrientations: [PaperOrientation] = [],
        blankPages: Set<Int> = [], notePages: [Int] = []
    ) {
        self.layout = layout
        self.notePages = Set(notePages.map { $0 + 1 })
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

    /// The 1-based page number of the `index`th page of the document's own, past the note pages among them.
    func bodyPage(at index: Int) -> Int? {
        let pages = sheets.flatMap { $0.sides.flatMap { $0.pages.compactMap { $0 } } }
        let body = pages.filter { !notePages.contains($0) }.sorted()
        return body.indices.contains(index) ? body[index] : nil
    }

    func rowID(containing page: Int) -> Int? {
        rows.first { row in row.sheets.contains { sheet in sheet.sides.contains { $0.pages.contains(page) } } }?.id
    }

    var isBooklet: Bool { layout.kind == .booklet }

    /// The pages of the finished piece, blank halves included, which is what the press bar calls its finished pages.
    var pageCount: Int { sheets.reduce(0) { $0 + $1.sides.reduce(0) { $0 + $1.pages.count } } }

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
    /// The tray zooms out to half the size that fits the window.
    static let minimumZoom: CGFloat = 0.5
    /// It zooms in to two and a half times the size that fits the window, and always far enough to show the sheets
    /// at twice their real size: fitted to a small window, a booklet sheet is under a quarter of its real size, so a
    /// limit on the fitted size alone did not even reach the size it prints at.
    static let fittedZoomLimit: CGFloat = 2.5
    static let largestScale: CGFloat = 2
    /// One step of the zoom buttons and of ⌘+ and ⌘−.
    static let zoomStep: CGFloat = 1.25

    /// Display points per PDF point at zoom 1, where the sheets fit the window.
    let fitScale: CGFloat
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
        let widthScale = pageWidth / (layout.kind == .handout3 ? layout.sheetSize.width : layout.logicalPageSize.width)
        let sheetHeight =
            mixedOrientations ? max(layout.sheetSize.width, layout.sheetSize.height) : layout.sheetSize.height
        let heightScale =
            viewportHeight.isFinite ? max(viewportHeight - Self.sheetChrome, 120) / sheetHeight : widthScale
        fitScale = min(widthScale, heightScale)
        scale = fitScale * Self.clampedZoom(zoom, fitScale: fitScale)
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

    var maximumZoom: CGFloat { Self.maximumZoom(fitScale: fitScale) }

    func clampedZoom(_ zoom: CGFloat) -> CGFloat { Self.clampedZoom(zoom, fitScale: fitScale) }

    private static func maximumZoom(fitScale: CGFloat) -> CGFloat {
        max(fittedZoomLimit, largestScale / max(fitScale, 0.01))
    }

    private static func clampedZoom(_ zoom: CGFloat, fitScale: CGFloat) -> CGFloat {
        min(max(zoom, minimumZoom), maximumZoom(fitScale: fitScale))
    }
}

/// A stretch of paper along one direction of the tray: a sheet's height, or the width of one of its sides.
struct TraySegment: Equatable {
    var start: CGFloat
    var length: CGFloat
    var end: CGFloat { start + length }
}

/// Where a spot is along one direction of the tray, in terms that survive a zoom. The paper grows with the zoom but
/// the headings, captions and gaps around it do not, so a spot on paper is kept as a fraction of it, and a spot off
/// paper as its distance from the paper before it (or before the first).
enum TrayMark: Equatable {
    case before(CGFloat)
    case on(Int, CGFloat)
    case after(Int, CGFloat)

    init(_ value: CGFloat, along segments: [TraySegment]) {
        guard let first = segments.first, value >= first.start else {
            self = .before((segments.first?.start ?? 0) - value)
            return
        }
        let index = segments.lastIndex { $0.start <= value } ?? 0
        let segment = segments[index]
        self =
            value <= segment.end && segment.length > 0
            ? .on(index, (value - segment.start) / segment.length) : .after(index, value - segment.end)
    }

    func value(along segments: [TraySegment]) -> CGFloat {
        switch self {
        case .before(let distance):
            return (segments.first?.start ?? 0) - distance
        case .on(let index, let fraction):
            guard let segment = segments.last.map({ index < segments.count ? segments[index] : $0 }) else {
                return 0
            }
            return segment.start + fraction * segment.length
        case .after(let index, let distance):
            guard let segment = segments.last.map({ index < segments.count ? segments[index] : $0 }) else {
                return distance
            }
            return segment.end + distance
        }
    }

    /// The row a vertical mark is in: the one whose paper it is on or follows; the first row above the rows.
    var row: Int {
        switch self {
        case .before: 0
        case .on(let index, _), .after(let index, _): index
        }
    }
}

/// Where everything sits in the tray's scroll view, worked out from the numbers the tray is drawn with, so that a zoom
/// can keep the spot under the pointer where it is. The two heights that depend on text are measured by the tray.
struct TrayGeometry: Equatable {
    static let topPadding: CGFloat = 22
    static let headerSpacing: CGFloat = 30
    /// Room below the first sheet, so its captions do not touch the press bar.
    static let bottomClearance: CGFloat = 16
    static let bottomPadding: CGFloat = 40
    static let rowSpacing: CGFloat = 34
    /// Between a sheet's heading and its paper.
    static let headingSpacing: CGFloat = 10
    /// Between the paper and its captions.
    static let captionSpacing: CGFloat = 9
    static let captionHeight: CGFloat = 20

    /// What the tray is laid out from, apart from the zoom.
    struct Context: Equatable {
        /// A row of the tray: how many sheets sit in it, how many sides each sheet shows, and a side's full size in
        /// PDF points.
        struct Row: Equatable {
            var sheets: Int
            var sides: Int
            var paper: CGSize
        }

        var layout: PrintLayout
        var mixedOrientations: Bool
        var rows: [Row]
        var showsCaptions: Bool
        /// The scroll view's size, scroll bars included.
        var width: CGFloat
        var height: CGFloat
        /// How thick a legacy scroll bar is, or 0 where scroll bars lie over the content.
        var scroller: CGFloat
        /// The measured heights of the instructions above the sheets and of a sheet's heading.
        var headerHeight: CGFloat
        var headingHeight: CGFloat

        init(
            layout: PrintLayout, mixedOrientations: Bool, rows: [Row], showsCaptions: Bool, width: CGFloat,
            height: CGFloat, scroller: CGFloat = 0, headerHeight: CGFloat, headingHeight: CGFloat
        ) {
            self.layout = layout
            self.mixedOrientations = mixedOrientations
            self.rows = rows
            self.showsCaptions = showsCaptions
            self.width = width
            self.height = height
            self.scroller = scroller
            self.headerHeight = headerHeight
            self.headingHeight = headingHeight
        }

        init(
            tray: PrintTray, showsCaptions: Bool, width: CGFloat, height: CGFloat, scroller: CGFloat,
            headerHeight: CGFloat, headingHeight: CGFloat
        ) {
            let layout = tray.layout
            self.init(
                layout: layout, mixedOrientations: Set(tray.sheets.map(\.orientation)).count > 1,
                rows: tray.rows.map { row in
                    let sheet = row.sheets.first
                    // As `TraySheetView` draws them: plain sheets lie the way they were made, the rest as the layout.
                    let landscape = sheet?.orientation == .landscape
                    let paper = (layout.kind == .normal ? layout.oriented(landscape) : layout).sheetSize
                    return Row(sheets: row.sheets.count, sides: sheet?.sides.count ?? 1, paper: paper)
                },
                showsCaptions: showsCaptions, width: width, height: height, scroller: scroller,
                headerHeight: headerHeight, headingHeight: headingHeight)
        }
    }

    let metrics: TrayMetrics
    /// The instructions keep the width of the sheets at zoom 1, so that they wrap the same at every zoom.
    let headerWidth: CGFloat
    /// The header and the rows share this width; rows narrower than the header sit in its middle.
    let blockWidth: CGFloat
    /// Wider than the window: the tray scrolls sideways.
    let scrollsSideways: Bool
    /// The left edge of the instructions and of the rows' block.
    let blockLeft: CGFloat
    let rowsLeft: CGFloat
    let rowTops: [CGFloat]
    let rowHeights: [CGFloat]
    /// Each row's paper, down the tray.
    let papers: [TraySegment]
    let contentSize: CGSize
    let viewportSize: CGSize
    private let rows: [Context.Row]
    private let scale: CGFloat

    init(context: Context, zoom: CGFloat) {
        let layout = context.mixedOrientations ? context.layout.oriented(true) : context.layout
        let viewportHeight =
            context.height - Self.topPadding - context.headerHeight - Self.headerSpacing - Self.bottomClearance
        // The sheets are sized as if a legacy scroll bar always took its width, so that one coming and going does
        // not resize them.
        func measure(_ zoom: CGFloat) -> TrayMetrics {
            TrayMetrics(
                layout: layout, viewportWidth: context.width - context.scroller, viewportHeight: viewportHeight,
                mixedOrientations: context.mixedOrientations, zoom: zoom)
        }
        let metrics = measure(zoom)
        self.metrics = metrics
        rows = context.rows
        scale = metrics.scale
        let captions = context.showsCaptions ? Self.captionSpacing + Self.captionHeight : 0
        var top = Self.topPadding + context.headerHeight + Self.headerSpacing
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var papers: [TraySegment] = []
        for row in context.rows {
            let paper = row.paper.height * metrics.scale
            let height = context.headingHeight + Self.headingSpacing + paper + captions
            tops.append(top)
            heights.append(height)
            papers.append(TraySegment(start: top + context.headingHeight + Self.headingSpacing, length: paper))
            top += height + Self.rowSpacing
        }
        rowTops = tops
        rowHeights = heights
        self.papers = papers
        let contentHeight = (heights.isEmpty ? top : top - Self.rowSpacing) + Self.bottomPadding
        headerWidth = measure(1).rowWidth
        blockWidth = max(metrics.rowWidth, headerWidth)
        // A legacy scroll bar takes its room from what the tray shows only while it is there: down the side when the
        // tray is taller than what shows, across the bottom when it is wider. Either can bring the other.
        let contentWidth = blockWidth + 2 * TrayMetrics.padding
        var tall = contentHeight > context.height
        // Zoomed out, the instructions keep their width and may be the ones that do not fit.
        var wide = contentWidth > context.width - (tall ? context.scroller : 0)
        if !tall, wide, contentHeight > context.height - context.scroller {
            tall = true
        }
        if !wide, tall, contentWidth > context.width - context.scroller {
            wide = true
        }
        let visibleWidth = context.width - (tall ? context.scroller : 0)
        scrollsSideways = wide
        blockLeft = wide ? TrayMetrics.padding : (visibleWidth - blockWidth) / 2
        rowsLeft = blockLeft + (blockWidth - metrics.rowWidth) / 2
        contentSize = CGSize(width: wide ? contentWidth : visibleWidth, height: contentHeight)
        viewportSize = CGSize(width: visibleWidth, height: context.height - (wide ? context.scroller : 0))
    }

    /// The sides of `row`, across the tray: sheets side by side, each with its sides side by side.
    func sides(ofRow row: Int) -> [TraySegment] {
        guard let shape = rows.indices.contains(row) ? rows[row] : rows.last else { return [] }
        let side = shape.paper.width * scale
        let sheet = side * CGFloat(shape.sides) + TrayMetrics.sideSpacing * CGFloat(shape.sides - 1)
        return (0..<shape.sheets).flatMap { index in
            let left = rowsLeft + CGFloat(index) * (sheet + TrayMetrics.twoUpSpacing)
            return (0..<shape.sides).map {
                TraySegment(start: left + CGFloat($0) * (side + TrayMetrics.sideSpacing), length: side)
            }
        }
    }

    /// The scroll position that keeps `spot` over the same place on the tray after the zoom changes it from `old` to
    /// `self`. Positions and spots are the scroll view's: an offset is where its top-left corner is in the content,
    /// and a spot is a point of the scroll view, which reaches `topInset` up under the bar above the tray.
    func offset(keeping spot: CGPoint, scrolledTo offset: CGPoint, in old: TrayGeometry, topInset: CGFloat) -> CGPoint {
        let point = CGPoint(x: offset.x + spot.x, y: offset.y + spot.y)
        let y = TrayMark(point.y, along: old.papers)
        // The instructions above the rows keep their size; a spot on them keeps its distance from their left edge.
        let x =
            point.y < (old.rowTops.first ?? .infinity)
            ? blockLeft + point.x - old.blockLeft
            : TrayMark(point.x, along: old.sides(ofRow: y.row)).value(along: sides(ofRow: y.row))
        return clamped(CGPoint(x: x - spot.x, y: y.value(along: papers) - spot.y), topInset: topInset)
    }

    /// The nearest scroll position the tray can take. At the top, the scroll view's corner is `topInset` above the
    /// content; at the bottom, the content's end meets the bottom of the scroll view.
    func clamped(_ offset: CGPoint, topInset: CGFloat) -> CGPoint {
        CGPoint(
            x: scrollsSideways ? min(max(offset.x, 0), max(contentSize.width - viewportSize.width, 0)) : 0,
            y: min(max(offset.y, -topInset), max(contentSize.height - viewportSize.height, 0) - topInset))
    }

    /// The scroll position that shows `row` at the top of the visible area; the first row shows the instructions too.
    func offset(showingRow row: Int, topInset: CGFloat, x: CGFloat) -> CGPoint {
        let y = row > 0 && rowTops.indices.contains(row) ? rowTops[row] - topInset : -topInset
        return clamped(CGPoint(x: x, y: y), topInset: topInset)
    }

    /// The top-most row with anything showing in the visible area, which starts `top` down the content.
    func rowIndex(atTop top: CGFloat) -> Int {
        rowTops.indices.first { rowTops[$0] + rowHeights[$0] > top + 0.5 } ?? max(rowTops.count - 1, 0)
    }
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

    /// What the sheets make, and how they are printed, in two lines: what is made of how much paper, then the binding.
    /// How to stack and fold them is left to the fold view. The first line comes in Markdown emphasis.
    /// - Parameters:
    ///   - sheets: The sheets of paper it takes.
    ///   - pages: The pages of the finished piece, blank halves included, as the press bar counts them.
    static func instructions(_ layout: PrintLayout, sheets: Int, pages: Int, language: String) -> String {
        // A number stays with its unit when the line folds: "1" and "pages" never part.
        func together(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }
        let paper = layout.sheet.shortName
        let sheetCount = together(format("%lld sheets", language: language, sheets))
        let pageText = together(pageCount(pages, language: language))
        let headline: String
        if layout.kind == .booklet {
            headline = format(
                "%3$@ booklet, %4$@, from %2$@ of %1$@", language: language, paper, sheetCount,
                (layout.sheet.halved ?? layout.sheet).shortName, pageText)
        } else {
            let landscape = layout.sheetSize.width > layout.sheetSize.height
            headline = format(
                "%3$@ on %2$@ of %1$@", language: language,
                together(format(landscape ? "%@ landscape" : "%@ portrait", language: language, paper)), sheetCount,
                pageText)
        }
        let binding =
            switch layout.sentDuplex {
            case .none: "Single-sided"
            case .longEdge: "Duplex, long edge"
            case .shortEdge: "Duplex, short edge"
            }
        return "**\(headline)**\n" + string(binding, language: language)
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
            switch layout.sentDuplex {
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
        case .twoUp: return string("2 Pages on One Sheet", language: language)
        case .normal: return format(layout.duplex == .none ? "%@ Single" : "%@ Duplex", language: language, paper)
        }
    }

    /// The paper of a card whose title names something else.
    static func cardPaper(_ layout: PrintLayout, language: String) -> String? {
        switch layout.kind {
        case .normal: nil
        case .booklet: format("Paper: %@, Two-Sided", language: language, layout.sheet.shortName)
        case .twoUp, .handout3: format("Paper: %@", language: language, layout.sheet.shortName)
        }
    }

    /// The printer's rotation is not on the sheets' choices, so it is told under the summary.
    static func options(_ options: PrintOptions, layout: PrintLayout, language: String) -> String? {
        options.rotatesBackSides && layout.duplex != .none
            ? string("Back sides rotated 180°", language: language) : nil
    }

    /// The finished piece: how many pages it has and, when they are not all the document's, what they are.
    static func finished(
        pages: Int, body: Int, contents: Int, notes: Int, blanks: Int, language: String
    ) -> String {
        let parts = [
            contents + notes + blanks > 0 ? format("Body %lld", language: language, body) : nil,
            contents > 0 ? format("Contents %lld", language: language, contents) : nil,
            notes > 0 ? format("Notes %lld", language: language, notes) : nil,
            blanks > 0 ? format("Blank %lld", language: language, blanks) : nil,
        ].compactMap { $0 }
        guard let first = parts.first else { return format("Finished: %lld pages", language: language, pages) }
        let detail = parts.dropFirst().reduce(first) { format("%1$@, %2$@", language: language, $0, $1) }
        return format("Finished: %1$lld pages / %2$@", language: language, pages, detail)
    }

    /// The paper the finished piece takes.
    static func paper(_ name: String, sheets: Int, duplex: DuplexMode, language: String) -> String {
        format(
            "Paper: %1$@, %2$lld sheets (%3$@)", language: language, name, sheets,
            string(duplex == .none ? "One-Sided" : "Two-Sided", language: language))
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
