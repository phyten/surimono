import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor
public enum PageImageExporter {
    public enum ExportError: Error { case invalidPage, cannotEncode }

    nonisolated public static func effectiveDPI(size: CGSize, dpi: Double) -> Double {
        guard dpi.isFinite, dpi > 0, size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return 0 }
        return min(dpi, 12_000 * 72 / max(size.width, size.height))
    }

    nonisolated public static func image(_ page: PDFPage, dpi: Double) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let effective = effectiveDPI(size: size, dpi: dpi)
        guard effective > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ExportError.invalidPage }
        let width = max(1, Int(ceil(size.width * effective / 72)))
        let height = max(1, Int(ceil(size.height * effective / 72)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.invalidPage }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Quartz's drawing transform only scales down. Apply the resolution first, then /Rotate and the crop
        // origin at 1:1, otherwise 144 dpi produces small content centered on a correctly sized bitmap.
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        if let reference = page.pageRef {
            context.concatenate(
                reference.getDrawingTransform(
                    .cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            context.clip(to: box)
            context.drawPDFPage(reference)
            for annotation in page.annotations where annotation.shouldDisplay {
                annotation.draw(with: .cropBox, in: context)
            }
        }
        guard let image = context.makeImage() else { throw ExportError.invalidPage }
        return image
    }

    nonisolated public static func png(_ page: PDFPage, dpi: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.cannotEncode }
        let effective = effectiveDPI(size: page.bounds(for: .cropBox).size, dpi: dpi)
        CGImageDestinationAddImage(
            destination, try image(page, dpi: dpi),
            [kCGImagePropertyDPIWidth: effective, kCGImagePropertyDPIHeight: effective] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotEncode }
        return data as Data
    }

    /// Each worker owns its PDFKit objects; only serialized bytes cross the actor boundary.
    nonisolated public static func png(document data: Data, page index: Int, dpi: Double) async throws -> Data {
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data), let page = document.page(at: index) else {
            throw ExportError.invalidPage
        }
        return try png(page, dpi: dpi)
    }
}
