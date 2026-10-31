import AppKit
import CoreText
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
        _ document: PDFDocument, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool = false
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard document.pageCount > 0 else { throw CompositionError.emptyDocument }
        return try await compose(
            try Self.composingSource(of: document), pageCount: document.pageCount, layout: layout, options: options,
            orientsEachPage: orientsEachPage)
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
        _ source: CGPDFDocument, pageCount: Int, layout: PrintLayout, options: PrintOptions, orientsEachPage: Bool
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard pageCount > 0 else { throw CompositionError.emptyDocument }
        let logicalSize = layout.logicalPageSize(options: options)
        let margin = CGFloat(layout.logicalMarginsInMillimeters(options: options) * 72 / 25.4)
        guard options.marginsInMillimeters.isFinite, options.marginsInMillimeters >= 0,
            PDFDrawing.validGeometry(pageSize: logicalSize, margin: margin)
        else {
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
                        if options.showsPageNumbers {
                            if layout.kind == .handout3 {
                                let spaceBelow = slot < 2 ? 8 * 72 / 25.4 : options.marginsInMillimeters * 72 / 25.4
                                drawHandoutNumber(index + 1, below: rect, space: spaceBelow, context: context)
                            } else {
                                drawNumber(
                                    index + 1, in: rect, margin: margin, logicalSize: logicalSize,
                                    context: context)
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

    private func drawHandoutNumber(_ number: Int, below rect: CGRect, space: CGFloat, context: CGContext) {
        let text = NSAttributedString(
            string: String(number),
            attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let height = ascent + descent
        let padding: CGFloat = 2
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        if space >= height + 2 * padding {
            context.textPosition = CGPoint(
                x: rect.midX - width / 2, y: rect.minY - space / 2 - (ascent - descent) / 2)
        } else {
            // The last slot has no usable footer with zero or tiny margins; white backing preserves contrast.
            let backing = CGRect(x: rect.minX, y: rect.minY, width: width + 2 * padding, height: height + 2 * padding)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(backing)
            context.textPosition = CGPoint(x: backing.minX + padding, y: backing.minY + padding + descent)
        }
        CTLineDraw(line, context)
    }

    private func drawNumber(
        _ number: Int, in rect: CGRect, margin: CGFloat, logicalSize: CGSize, context: CGContext
    ) {
        let logicalRect = PDFDrawing.fittedRect(size: logicalSize, in: rect)
        let scale = logicalRect.width / logicalSize.width
        PageNumberDrawing.draw(number, in: logicalRect, margin: margin * scale, scale: scale, context: context)
    }
}
