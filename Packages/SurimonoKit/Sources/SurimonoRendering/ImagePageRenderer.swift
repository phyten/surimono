import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SurimonoCore

@MainActor
public struct ImagePageRenderer {
    public enum RenderingError: Error, Equatable {
        case invalidImage
        case invalidGeometry
        case pdfCreationFailed
    }

    public init() {}

    public func render(
        _ data: Data, pageSize: CGSize, marginsInMillimeters: Double = 15, autoRotatesPage: Bool = false
    ) async throws -> PDFDocument {
        try await render(
            data, pageSize: pageSize, margins: .uniform(marginsInMillimeters), autoRotatesPage: autoRotatesPage)
    }

    public func render(
        _ data: Data, pageSize: CGSize, margins pageMargins: PageMargins, autoRotatesPage: Bool = false
    ) async throws -> PDFDocument {
        try Task.checkCancellation()
        let margins = WebPaginator.Margins(pageMargins)
        guard PDFDrawing.validGeometry(pageSize: pageSize, margins: margins) else {
            throw RenderingError.invalidGeometry
        }
        let decoding = Task.detached(priority: Task.currentPriority) {
            try Self.decode(data, pageSize: pageSize, margins: margins, autoRotatesPage: autoRotatesPage)
        }
        let (image, size) = try await withTaskCancellationHandler {
            do {
                let decoded = try await decoding.value
                try Task.checkCancellation()
                return decoded
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            decoding.cancel()
        }
        let textArea = CGRect(
            x: margins.left, y: margins.bottom, width: size.width - margins.left - margins.right,
            height: size.height - margins.top - margins.bottom)
        let rect = PDFDrawing.fittedRect(size: CGSize(width: image.width, height: image.height), in: textArea)
        // The art box marks the image and its margins, so the screen can leave out the paper the image's shape does
        // not fill; printing still places the whole page.
        var artBox = CGRect(
            x: rect.minX - margins.left, y: rect.minY - margins.bottom,
            width: rect.width + margins.left + margins.right, height: rect.height + margins.top + margins.bottom
        ).intersection(CGRect(origin: .zero, size: size))
        let pageInfo = [kCGPDFContextArtBox: Data(bytes: &artBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
        do {
            return try await PDFDrawing.document(pageSize: size) { context in
                try Task.checkCancellation()
                context.beginPDFPage(pageInfo)
                context.interpolationQuality = .high
                context.draw(image, in: rect)
                context.endPDFPage()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RenderingError.pdfCreationFailed
        }
    }

    /// Copies of the pages cropped to their art boxes, for the screen. The pages themselves keep the whole paper,
    /// because the sheets are composed from their crop boxes.
    static func viewDocument(of document: PDFDocument) -> PDFDocument {
        let cropped = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else { continue }
            copy.setBounds(page.bounds(for: .artBox), for: .cropBox)
            cropped.insert(copy, at: cropped.pageCount)
        }
        return cropped
    }

    nonisolated static func contentSize(_ data: Data) throws -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue > 0, height.doubleValue > 0
        else { throw RenderingError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private nonisolated static func decode(
        _ data: Data, pageSize: CGSize, margins: WebPaginator.Margins, autoRotatesPage: Bool
    ) throws -> (CGImage, CGSize) {
        try Task.checkCancellation()
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.intValue > 0, height.intValue > 0
        else { throw RenderingError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let imageWidth = CGFloat(swapsAxes ? height.intValue : width.intValue)
        let imageHeight = CGFloat(swapsAxes ? width.intValue : height.intValue)
        var size = pageSize
        if autoRotatesPage && imageWidth > imageHeight && size.width < size.height {
            size = CGSize(width: size.height, height: size.width)
        }
        let fitScale = min(
            (size.width - margins.left - margins.right) / imageWidth,
            (size.height - margins.top - margins.bottom) / imageHeight)
        // 300 dpi at the fitted print size preserves print detail without decoding unused native pixels.
        // Capping by the source's long edge also prevents upsampling small images.
        let maximumPixelSize = max(
            1, min(max(imageWidth, imageHeight), floor(max(imageWidth, imageHeight) * fitScale * 300 / 72)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            // Decode eagerly on this worker so PDF drawing cannot defer the work back to the main actor.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        try Task.checkCancellation()
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        try Task.checkCancellation()
        guard let image else { throw RenderingError.invalidImage }
        return (image, size)
    }
}
