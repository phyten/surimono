import AppKit
import PDFKit
import SurimonoCore

public struct PDFComposer: Sendable {
    public enum CompositionError: Error, Equatable {
        case emptyDocument
        case invalidPage(Int)
        case invalidMargins
        case pdfCreationFailed
    }

    public init() {}

    /// How the logical pages took their mirrored margins when they were laid out. A text or an image on the swapped
    /// side of a spread had its content moved toward the binding then, by its place in the whole document. Printing
    /// only some of the pages can put a page on the other side, and it is not laid out again for that.
    public struct LaidOutSides: Equatable, Sendable {
        /// The pages were moved for their sides. A PDF's own pages are fitted whole and never were.
        public var movesContent: Bool
        /// Pages that were left where they are: a note page keeps the margins of its own style.
        public var fixedPages: Set<Int>

        public init(movesContent: Bool = false, fixedPages: Set<Int> = []) {
            self.movesContent = movesContent
            self.fixedPages = fixedPages
        }
    }

    /// How far the content of the logical page at `index` has to move to the right, in the points of that page, to
    /// keep its inside margin on the side of the binding when it is printed as the `position`th page.
    public nonisolated static func sideCorrection(
        forPage index: Int, at position: Int, layout: PrintLayout, options: PrintOptions, sides: LaidOutSides
    ) -> CGFloat {
        guard sides.movesContent, !sides.fixedPages.contains(index), layout.mirrorsMargins(options: options),
            layout.swapsSides(onPage: index) != layout.swapsSides(onPage: position)
        else { return 0 }
        let margins = layout.logicalMargins(options: options)
        let shift = CGFloat((margins.right - margins.left) * 72 / 25.4)
        return layout.swapsSides(onPage: position) ? shift : -shift
    }

    /// The corrections of every page of a range that needs one, by the page's index in the document.
    public nonisolated static func sideCorrections(
        pages: [Int]?, layout: PrintLayout, options: PrintOptions, sides: LaidOutSides
    ) -> [Int: CGFloat] {
        var corrections: [Int: CGFloat] = [:]
        for (position, index) in (pages ?? []).enumerated() {
            let correction = sideCorrection(
                forPage: index, at: position, layout: layout, options: options, sides: sides)
            if correction != 0 { corrections[index] = correction }
        }
        return corrections
    }

    @MainActor public func compose(
        _ document: PDFDocument, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool = false,
        furniture: PageFurniture.Context = PageFurniture.Context(), pages: [Int]? = nil,
        sides: LaidOutSides = LaidOutSides()
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard document.pageCount > 0 else { throw CompositionError.emptyDocument }
        let sheets = try await compose(
            Source(document, bytes: nil), layout: layout, options: options, orientsEachPage: orientsEachPage,
            furniture: furniture, pages: pages, sides: sides)
        guard let output = PDFDocument(data: sheets.data) else { throw CompositionError.pdfCreationFailed }
        return output
    }

    /// The logical pages as they stand on the sheets: a page of `pageSize` each, fitted the way `compose` fits them
    /// into a slot. A PDF's pages keep their own size until then. Pages already at that size are copied as they are.
    /// - Parameter corrections: How far the content of some pages moves to the right (`sideCorrections`), so that a
    ///   booklet of a range reads here as it does on its sheets.
    @MainActor public func fitted(
        _ document: PDFDocument, pageSize: CGSize, corrections: [Int: CGFloat] = [:]
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard document.pageCount > 0 else { throw CompositionError.emptyDocument }
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else {
            throw CompositionError.pdfCreationFailed
        }
        let isFitted = (0..<copy.pageCount).allSatisfy { index in
            guard let page = copy.page(at: index) else { return false }
            let box = page.bounds(for: .cropBox).size
            let size = page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
            return abs(size.width - pageSize.width) < 0.5 && abs(size.height - pageSize.height) < 0.5
        }
        if isFitted, corrections.isEmpty { return copy }
        return try await PDFDrawing.document(pageSize: pageSize) { context in
            for index in 0..<copy.pageCount {
                await Task.yield()
                try Task.checkCancellation()
                guard let page = copy.page(at: index)?.pageRef else {
                    throw CompositionError.invalidPage(index + 1)
                }
                context.beginPDFPage(nil)
                try draw(
                    page, in: CGRect(origin: .zero, size: pageSize), context: context, index: index,
                    shift: corrections[index] ?? 0)
                context.endPDFPage()
            }
        }
    }

    enum Source: Sendable {
        case bytes(Data)
        case edited(count: Int, page: @MainActor @Sendable (Int) throws -> Data)

        @MainActor init(_ document: PDFDocument, bytes: Data?) {
            if let bytes {
                self = .bytes(bytes)
            } else {
                // PDFKit edits are visible after serialization. Snapshot only the requested page on its owner.
                self = .edited(count: document.pageCount) { index in
                    try Task.checkCancellation()
                    guard let bytes = document.page(at: index)?.dataRepresentation else {
                        throw CompositionError.invalidPage(index + 1)
                    }
                    return bytes
                }
            }
        }
    }

    private func quartzDocument(_ bytes: Data) throws -> CGPDFDocument {
        guard let provider = CGDataProvider(data: bytes as CFData), let pdf = CGPDFDocument(provider) else {
            throw CompositionError.pdfCreationFailed
        }
        return pdf
    }

    /// Each job opens its own Quartz document and draws into a context owned by that job alone.
    @concurrent func compose(
        _ input: Source, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool,
        furniture: PageFurniture.Context = PageFurniture.Context(), pages: [Int]? = nil,
        sides: LaidOutSides = LaidOutSides()
    ) async throws -> (data: Data, orientations: [PaperOrientation]) {
        try Task.checkCancellation()
        let source: CGPDFDocument?
        let pageCount: Int
        switch input {
        case .bytes(let data):
            let pdf = try quartzDocument(data)
            source = pdf
            pageCount = pdf.numberOfPages
        case .edited(let count, _):
            source = nil
            pageCount = count
        }
        guard pageCount > 0 else { throw CompositionError.emptyDocument }
        let logicalSize = layout.logicalPageSize(options: options)
        let margins = WebPaginator.Margins(layout.logicalMargins(options: options))
        guard options.margins.isValid, PDFDrawing.validGeometry(pageSize: logicalSize, margins: margins) else {
            throw CompositionError.invalidMargins
        }
        // Only some of the pages go on the sheets; the header and footer still count the whole document.
        let plan =
            pages.map { Imposition.plan(pages: $0, layout: layout) }
            ?? Imposition.plan(pageCount: pageCount, layout: layout)
        // Which side of a spread a page is on follows its place among the pages that print; its number does not.
        let positions = Dictionary((pages ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let corrections = Self.sideCorrections(pages: pages, layout: layout, options: options, sides: sides)
        let size = layout.sheetSize
        let bytes = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: bytes),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw CompositionError.pdfCreationFailed
        }
        var orientations: [PaperOrientation] = []
        do {
            for side in plan.sides {
                try Task.checkCancellation()
                var snapshots: [Int: CGPDFDocument] = [:]
                if case .edited(_, let readPage) = input {
                    for index in side.slots.compactMap({ $0 }) {
                        snapshots[index] = try quartzDocument(await readPage(index))
                    }
                }
                func page(_ index: Int) -> CGPDFPage? {
                    source?.page(at: index + 1) ?? snapshots[index]?.page(at: 1)
                }
                var layout = layout
                if orientsEachPage && layout.kind == .normal && layout.duplex == .none,
                    let index = side.slots.first ?? nil, let page = page(index)
                {
                    let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
                    let size =
                        page.rotationAngle % 180 == 0
                        ? box.size : CGSize(width: box.height, height: box.width)
                    layout = layout.oriented(size.width > size.height)
                }
                let size = layout.sheetSize
                orientations.append(size.width > size.height ? .landscape : .portrait)
                var box = CGRect(origin: .zero, size: size)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.saveGState()
                if options.rotatesBackSides && side.isBack {
                    context.translateBy(x: size.width, y: size.height)
                    context.rotate(by: .pi)
                }
                for (slot, index) in side.slots.enumerated() {
                    guard let index else { continue }
                    guard let page = page(index) else {
                        throw CompositionError.invalidPage(index + 1)
                    }
                    let slotRect = layout.slotRect(at: slot, options: options)
                    let rect = CGRect(
                        x: slotRect.minX * size.width, y: (1 - slotRect.maxY) * size.height,
                        width: slotRect.width * size.width, height: slotRect.height * size.height)
                    let position = positions[index] ?? index
                    try draw(page, in: rect, context: context, index: index, shift: corrections[index] ?? 0)
                    if layout.kind == .handout3 {
                        if let lines = Self.furnitureLines(
                            onPage: index, at: position, pageCount: pageCount, layout: layout, options: options,
                            context: furniture)
                        {
                            drawHandout(lines, slot: slot, in: rect, options: options, context: context)
                        }
                    } else if let placement = Self.furniture(
                        onPage: index, at: position, pageCount: pageCount, layout: layout, options: options,
                        context: furniture)
                    {
                        Self.draw(placement, in: rect, context: context)
                    }
                }
                if let memo = layout.memoRect(options: options) {
                    let rect = CGRect(
                        x: memo.minX * size.width, y: (1 - memo.maxY) * size.height,
                        width: memo.width * size.width, height: memo.height * size.height)
                    drawMemo(in: rect, context: context)
                }
                context.restoreGState()
                context.endPDFPage()
            }
        } catch {
            context.closePDF()
            throw error
        }
        context.closePDF()
        try Task.checkCancellation()
        return (bytes as Data, orientations)
    }

    private func drawMemo(in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        context.setLineWidth(0.5)
        let spacing = 8.0 * 72 / 25.4
        for offset in stride(from: spacing, through: rect.height, by: spacing) {
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY - offset))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - offset))
        }
        context.strokePath()
    }

    /// - Parameter shift: How far the page's content moves to the right inside `rect`, in the page's own points.
    private func draw(
        _ page: CGPDFPage, in rect: CGRect, context: CGContext, index: Int, shift: CGFloat = 0
    ) throws {
        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard PDFDrawing.validGeometry(pageSize: box.size, margin: 0), !box.isNull else {
            throw CompositionError.invalidPage(index + 1)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        let rotatedSize = page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let fitted = PDFDrawing.fittedRect(size: rotatedSize, in: rect)
        let scale = fitted.width / rotatedSize.width
        context.translateBy(x: fitted.minX, y: fitted.minY)
        context.scaleBy(x: scale, y: scale)
        if shift != 0 { context.translateBy(x: shift, y: 0) }
        // Quartz only scales down, so fit explicitly before applying /Rotate and the crop-box origin.
        context.concatenate(
            page.getDrawingTransform(
                .cropBox, rect: CGRect(origin: .zero, size: rotatedSize), rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
    }

    private func drawHandout(
        _ lines: PageFurniture.Lines, slot: Int, in rect: CGRect, options: PrintOptions, context: CGContext
    ) {
        func points(_ millimeters: Double) -> CGFloat { CGFloat(millimeters * 72 / 25.4) }
        // The gap between two slots holds one page's footer and the next page's header: each keeps to its half.
        let half = points(PrintLayout.handoutGapInMillimeters) / 2
        PageFurnitureDrawing.drawHandoutRow(
            lines.top, beside: rect, above: true, space: slot == 0 ? points(options.margins.top) : half,
            padding: slot == 0 ? 2 : 0.5, rule: lines.headRule, context: context)
        PageFurnitureDrawing.drawHandoutRow(
            lines.bottom, beside: rect, above: false, space: slot < 2 ? half : points(options.margins.bottom),
            padding: slot < 2 ? 0.5 : 2, rule: lines.footRule, context: context)
    }

}

/// The header and footer the sheets draw on one logical page, and the margins they stand in, measured on a page of
/// `pageSize` as the page lies on its sheet.
public struct FurniturePlacement: Equatable, Sendable {
    public var latexFooter: PageFurniture.LaTeXFooter? = nil
    public let lines: PageFurniture.Lines
    public let margins: WebPaginator.Margins
    public let pageSize: CGSize
}

extension PDFComposer {
    /// What is drawn where on a logical page: the one answer the sheets and the view mode's paper share. Nil when the
    /// page has no header or footer, and for the 3-up handout, whose lines stand beside the page (`furnitureLines`).
    /// - Parameter position: The page's place among the pages that print; its side of a spread follows it, while the
    ///   number it shows is its own.
    public static func furniture(
        onPage index: Int, at position: Int, pageCount: Int, layout: PrintLayout, options: PrintOptions,
        context: PageFurniture.Context
    ) -> FurniturePlacement? {
        guard layout.kind != .handout3,
            let lines = furnitureLines(
                onPage: index, at: position, pageCount: pageCount, layout: layout, options: options, context: context)
        else { return nil }
        let margins = WebPaginator.Margins(layout.logicalMargins(options: options))
        let verso = layout.mirrorsMargins(options: options) && layout.swapsSides(onPage: position)
        return FurniturePlacement(
            latexFooter: context.latexFooter, lines: lines, margins: verso ? margins.mirrored : margins,
            pageSize: layout.logicalPageSize(options: options))
    }

    /// The text of a page's header and footer, wherever it stands.
    static func furnitureLines(
        onPage index: Int, at position: Int, pageCount: Int, layout: PrintLayout, options: PrintOptions,
        context: PageFurniture.Context
    ) -> PageFurniture.Lines? {
        options.furniture.lines(
            forPage: index, pageCount: pageCount, context: context, hasFacingPages: layout.hasFacingPages,
            rightBound: layout.isRightBound, position: position)
    }

    /// Draws a placement on its page laid into `rect`, at the page's scale there.
    /// - Parameter asOutlines: Draws the letters as shapes, so that they add no text to the page.
    static func draw(
        _ placement: FurniturePlacement, in rect: CGRect, asOutlines: Bool = false, context: CGContext
    ) {
        let logicalRect = PDFDrawing.fittedRect(size: placement.pageSize, in: rect)
        let scale = logicalRect.width / placement.pageSize.width
        let margins = placement.margins
        PageFurnitureDrawing.draw(
            placement.lines, in: logicalRect,
            margins: WebPaginator.Margins(
                top: margins.top * scale, left: margins.left * scale, bottom: margins.bottom * scale,
                right: margins.right * scale), scale: scale, latexFooter: placement.latexFooter, asOutlines: asOutlines,
            context: context)
    }
}
