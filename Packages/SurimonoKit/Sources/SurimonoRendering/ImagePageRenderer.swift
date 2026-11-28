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
        // The SVG deadline counts from here, before the bytes are read, copied or handed to WebKit.
        let deadline = ContinuousClock.now + SVGImageDrawing.timeout
        // Reading the SVG root and decoding pixels both stay off the main actor.
        let decoding = Task.detached(priority: Task.currentPriority) {
            try Self.decode(data, pageSize: pageSize, margins: margins, autoRotatesPage: autoRotatesPage)
        }
        let decoded = try await withTaskCancellationHandler {
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
        let ink: Ink
        let size: CGSize
        let rect: CGRect
        switch decoded {
        case .raster(let image, let paper):
            size = paper
            rect = PDFDrawing.fittedRect(
                size: CGSize(width: image.width, height: image.height), in: Self.textArea(size, margins: margins))
            ink = .raster(image)
        case .svg(let shape, let paper):
            size = paper
            rect = PDFDrawing.fittedRect(size: shape, in: Self.textArea(size, margins: margins))
            // An extreme shape can still fit to nothing; it is not placed as a sliver or a point.
            guard SVGIntrinsicSize.usable(rect.size), rect.width >= 0.01, rect.height >= 0.01,
                rect.minX.isFinite, rect.minY.isFinite
            else { throw RenderingError.invalidImage }
            ink = .vector(try await SVGImageDrawing.document(data, size: rect.size, until: deadline))
        }
        try Task.checkCancellation()
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
                switch ink {
                case .raster(let image):
                    context.interpolationQuality = .high
                    context.draw(image, in: rect)
                case .vector(let document):
                    guard let page = document.page(at: 1) else { break }
                    let box = page.getBoxRect(.cropBox)
                    context.saveGState()
                    context.translateBy(x: rect.minX, y: rect.minY)
                    context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
                    context.translateBy(x: -box.minX, y: -box.minY)
                    context.drawPDFPage(page)
                    context.restoreGState()
                }
                context.endPDFPage()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RenderingError.pdfCreationFailed
        }
    }

    /// What an image page draws: decoded pixels, or the vector page WebKit drew from an SVG file.
    private enum Ink {
        case raster(CGImage)
        case vector(CGPDFDocument)
    }

    private nonisolated static func textArea(_ size: CGSize, margins: WebPaginator.Margins) -> CGRect {
        CGRect(
            x: margins.left, y: margins.bottom, width: size.width - margins.left - margins.right,
            height: size.height - margins.top - margins.bottom)
    }

    /// The paper, turned to landscape for a wide image when the page follows each image's shape.
    private nonisolated static func paperSize(_ pageSize: CGSize, image: CGSize, autoRotatesPage: Bool) -> CGSize {
        autoRotatesPage && image.width > image.height && pageSize.width < pageSize.height
            ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
    }

    /// Copies of the pages cropped to their art boxes, for the screen. The pages themselves keep the whole paper,
    /// because the sheets are composed from their crop boxes.
    ///
    /// A page's copy shares its page dictionary with the page, so a crop box set on it would be saved with the logical
    /// document too. The pages are cut in a document of their own, read from the saved bytes; when that cannot be
    /// read, the screen shows the whole paper instead.
    static func viewDocument(of document: PDFDocument) -> PDFDocument {
        guard let data = document.dataRepresentation(), let cropped = PDFDocument(data: data),
            cropped.pageCount == document.pageCount
        else { return document }
        for index in 0..<cropped.pageCount {
            guard let page = cropped.page(at: index), let original = document.page(at: index) else { continue }
            page.setBounds(original.bounds(for: .artBox), for: .cropBox)
        }
        return cropped
    }

    nonisolated static func contentSize(_ data: Data) throws -> CGSize {
        if let reading = SVGIntrinsicSize.read(data) {
            guard case .size(let shape) = reading else { throw RenderingError.invalidImage }
            return shape
        }
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

    /// What the bytes decode to off the main actor: pixels, or an SVG's shape for WebKit to draw.
    private enum Decoded: @unchecked Sendable {
        // CGImage is immutable once made, so handing it to the main actor is safe.
        case raster(CGImage, paper: CGSize)
        case svg(CGSize, paper: CGSize)
    }

    private nonisolated static func decode(
        _ data: Data, pageSize: CGSize, margins: WebPaginator.Margins, autoRotatesPage: Bool
    ) throws -> Decoded {
        try Task.checkCancellation()
        if let reading = SVGIntrinsicSize.read(data) {
            guard case .size(let shape) = reading else { throw RenderingError.invalidImage }
            return .svg(shape, paper: paperSize(pageSize, image: shape, autoRotatesPage: autoRotatesPage))
        }
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
        let size = paperSize(
            pageSize, image: CGSize(width: imageWidth, height: imageHeight), autoRotatesPage: autoRotatesPage)
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
        return .raster(image, paper: size)
    }
}
