import CoreGraphics
import Foundation
import PDFKit

@MainActor
enum PDFDrawing {
    enum DrawingError: Error {
        case contextCreationFailed
        case invalidOutput
    }

    static func document(
        pageSize: CGSize, draw: (CGContext) async throws -> Void
    ) async throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw DrawingError.contextCreationFailed }
        do {
            try await draw(context)
        } catch {
            context.closePDF()
            throw error
        }
        context.closePDF()
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data as Data), document.pageCount > 0 else {
            throw DrawingError.invalidOutput
        }
        return document
    }

    static func validGeometry(pageSize: CGSize, margin: CGFloat) -> Bool {
        pageSize.width.isFinite && pageSize.height.isFinite && margin.isFinite && margin >= 0
            && pageSize.width > margin * 2 && pageSize.height > margin * 2
    }

    static func fittedRect(size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width,
            height: fitted.height)
    }
}
