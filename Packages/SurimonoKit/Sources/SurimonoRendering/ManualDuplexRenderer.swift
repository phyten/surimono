import CoreGraphics
import PDFKit
import SurimonoCore

@MainActor
public struct ManualDuplexRenderer {
    public enum PreparationError: Error { case invalidDocument, invalidSide, invalidGeometry }

    public init() {}

    public func document(from imposed: PDFDocument, sides: [ManualDuplexSide]) async throws -> PDFDocument {
        try Task.checkCancellation()
        // Reopen first: PDFKit edits may not yet be reflected by a pageRef, and shared pages must stay untouched.
        guard !sides.isEmpty, let data = imposed.dataRepresentation(), let source = PDFDocument(data: data),
            let first = sides.first, let page = source.page(at: first.sourceSideIndex)
        else { throw PreparationError.invalidDocument }
        return try await PDFDrawing.document(pageSize: page.bounds(for: .mediaBox).size) { context in
            for side in sides {
                await Task.yield()
                try Task.checkCancellation()
                guard let page = source.page(at: side.sourceSideIndex), let ref = page.pageRef else {
                    throw PreparationError.invalidSide
                }
                let box = page.bounds(for: .mediaBox)
                guard PDFDrawing.validGeometry(pageSize: box.size, margin: 0) else {
                    throw PreparationError.invalidGeometry
                }
                // Each imposed side keeps its exact physical dimensions, including completely blank backs.
                var outputBox = CGRect(origin: .zero, size: box.size)
                let boxData = Data(bytes: &outputBox, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.saveGState()
                if side.rotates180 {
                    context.translateBy(x: box.width, y: box.height)
                    context.rotate(by: .pi)
                }
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(ref)
                context.restoreGState()
                context.endPDFPage()
            }
        }
    }

    public func transportLayout(for imposedLayout: PrintLayout) throws -> PrintLayout {
        try PrintLayout(id: "manualDuplexTransport", kind: .normal, sheet: imposedLayout.sheet, duplex: .none)
            .oriented(imposedLayout.sheetSize.width > imposedLayout.sheetSize.height)
    }
}
