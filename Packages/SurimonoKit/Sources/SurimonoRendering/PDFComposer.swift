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
        _ document: PDFDocument, layout: PrintLayout, options: PrintOptions
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        guard document.pageCount > 0 else { throw CompositionError.emptyDocument }
        let margin = CGFloat(options.marginsInMillimeters * 72 / 25.4)
        guard PDFDrawing.validGeometry(pageSize: layout.logicalPageSize, margin: margin) else {
            throw CompositionError.invalidMargins
        }
        // PDFPage edits (including rotation) are not necessarily reflected in pageRef until serialized.
        guard let data = document.dataRepresentation(), let provider = CGDataProvider(data: data as CFData),
            let source = CGPDFDocument(provider)
        else { throw CompositionError.pdfCreationFailed }
        let plan = Imposition.plan(pageCount: document.pageCount, layout: layout)
        let size = layout.sheetSize
        do {
            return try await PDFDrawing.document(pageSize: size) { context in
                for side in plan.sides {
                    await Task.yield()
                    try Task.checkCancellation()
                    context.beginPDFPage(nil)
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
                        let slotRect = layout.slotRect(at: slot)
                        let rect = CGRect(
                            x: slotRect.minX * size.width, y: (1 - slotRect.maxY) * size.height,
                            width: slotRect.width * size.width, height: slotRect.height * size.height)
                        try draw(page, in: rect, context: context, index: index)
                        if options.showsPageNumbers {
                            drawNumber(
                                index + 1, in: rect, margin: margin, logicalSize: layout.logicalPageSize,
                                context: context)
                        }
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

    private func drawNumber(
        _ number: Int, in rect: CGRect, margin: CGFloat, logicalSize: CGSize, context: CGContext
    ) {
        let logicalRect = PDFDrawing.fittedRect(size: logicalSize, in: rect)
        let scale = logicalRect.width / logicalSize.width
        let text = NSAttributedString(
            string: String(number),
            attributes: [.font: NSFont.systemFont(ofSize: 8 * scale), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        // With zero margins, keep the label inside the page instead of clipping it below the media box.
        let centerY = logicalRect.minY + max(margin * scale / 2, (ascent + descent) / 2 + 2)
        context.textPosition = CGPoint(x: logicalRect.midX - width / 2, y: centerY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
}
