import CoreGraphics
import Foundation
import ImageIO
import PDFKit

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
        try Task.checkCancellation()
        let margin = CGFloat(marginsInMillimeters * 72 / 25.4)
        guard PDFDrawing.validGeometry(pageSize: pageSize, margin: margin) else { throw RenderingError.invalidGeometry }
        let decoding = Task.detached(priority: Task.currentPriority) {
            try Self.decode(data, pageSize: pageSize, margin: margin, autoRotatesPage: autoRotatesPage)
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
        let rect = PDFDrawing.fittedRect(
            size: CGSize(width: image.width, height: image.height),
            in: CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin))
        do {
            return try await PDFDrawing.document(pageSize: size) { context in
                try Task.checkCancellation()
                context.beginPDFPage(nil)
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

    private nonisolated static func decode(
        _ data: Data, pageSize: CGSize, margin: CGFloat, autoRotatesPage: Bool
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
        let fitScale = min((size.width - 2 * margin) / imageWidth, (size.height - 2 * margin) / imageHeight)
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
