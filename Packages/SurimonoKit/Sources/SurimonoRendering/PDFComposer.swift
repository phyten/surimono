import AppKit
import PDFKit
import SurimonoCore

@MainActor
public struct PDFComposer {
    public enum CompositionError: Error, Equatable {
        case emptyDocument
        case invalidPage(Int)
        case invalidMargins
        case pdfCreationFailed
    }

    public init() {}

    public func compose(
        _ document: PDFDocument, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool = false,
        furniture: PageFurniture.Context = PageFurniture.Context()
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard document.pageCount > 0 else { throw CompositionError.emptyDocument }
        return try await compose(
            try Self.composingSource(of: document), pageCount: document.pageCount, layout: layout, options: options,
            orientsEachPage: orientsEachPage, furniture: furniture)
    }

    /// The pages of `document` as drawn into the sheets. A caller composing the same document again may keep it.
    static func composingSource(of document: PDFDocument) throws -> CGPDFDocument {
        // PDFPage edits (including rotation) are not necessarily reflected in pageRef until serialized.
        guard let data = document.dataRepresentation(), let provider = CGDataProvider(data: data as CFData),
            let source = CGPDFDocument(provider)
        else { throw CompositionError.pdfCreationFailed }
        return source
    }

    func compose(
        _ source: CGPDFDocument, pageCount: Int, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool,
        furniture: PageFurniture.Context = PageFurniture.Context()
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard pageCount > 0 else { throw CompositionError.emptyDocument }
        let logicalSize = layout.logicalPageSize(options: options)
        let margins = WebPaginator.Margins(layout.logicalMargins(options: options))
        guard options.margins.isValid, PDFDrawing.validGeometry(pageSize: logicalSize, margins: margins) else {
            throw CompositionError.invalidMargins
        }
        let plan = Imposition.plan(pageCount: pageCount, layout: layout)
        let size = layout.sheetSize
        do {
            return try await PDFDrawing.document(pageSize: size) { context in
                for side in plan.sides {
                    await Task.yield()
                    try Task.checkCancellation()
                    var layout = layout
                    if orientsEachPage && layout.kind == .normal && layout.duplex == .none,
                        let index = side.slots.first ?? nil, let page = source.page(at: index + 1)
                    {
                        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
                        let size =
                            page.rotationAngle % 180 == 0
                            ? box.size : CGSize(width: box.height, height: box.width)
                        layout = layout.oriented(size.width > size.height)
                    }
                    let size = layout.sheetSize
                    let logicalSize = layout.logicalPageSize(options: options)
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
                        guard let page = source.page(at: index + 1) else {
                            throw CompositionError.invalidPage(index + 1)
                        }
                        let slotRect = layout.slotRect(at: slot, options: options)
                        let rect = CGRect(
                            x: slotRect.minX * size.width, y: (1 - slotRect.maxY) * size.height,
                            width: slotRect.width * size.width, height: slotRect.height * size.height)
                        try draw(page, in: rect, context: context, index: index)
                        if let lines = options.furniture.lines(
                            forPage: index, pageCount: pageCount, context: furniture,
                            hasFacingPages: layout.hasFacingPages)
                        {
                            if layout.kind == .handout3 {
                                drawHandout(lines, slot: slot, in: rect, options: options, context: context)
                            } else {
                                let verso = layout.mirrorsMargins(options: options) && index % 2 == 1
                                drawFurniture(
                                    lines, in: rect, margins: verso ? margins.mirrored : margins,
                                    logicalSize: logicalSize, context: context)
                            }
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
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CompositionError {
            throw error
        } catch {
            throw CompositionError.pdfCreationFailed
        }
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

    private func draw(_ page: CGPDFPage, in rect: CGRect, context: CGContext, index: Int) throws {
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
        let gap = points(PrintLayout.handoutGapInMillimeters)
        PageFurnitureDrawing.drawHandoutRow(
            lines.top, beside: rect, above: true, space: slot == 0 ? points(options.margins.top) : gap,
            context: context)
        PageFurnitureDrawing.drawHandoutRow(
            lines.bottom, beside: rect, above: false, space: slot < 2 ? gap : points(options.margins.bottom),
            context: context)
    }

    private func drawFurniture(
        _ lines: PageFurniture.Lines, in rect: CGRect, margins: WebPaginator.Margins, logicalSize: CGSize,
        context: CGContext
    ) {
        let logicalRect = PDFDrawing.fittedRect(size: logicalSize, in: rect)
        let scale = logicalRect.width / logicalSize.width
        PageFurnitureDrawing.draw(
            lines, in: logicalRect,
            margins: WebPaginator.Margins(
                top: margins.top * scale, left: margins.left * scale, bottom: margins.bottom * scale,
                right: margins.right * scale), scale: scale, context: context)
    }
}
