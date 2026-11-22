import CoreGraphics
import Foundation
import PDFKit

/// One cache per generation of reading pages. The worker owns its Quartz document. PDFKit edits, when present,
/// are serialized one requested page at a time by the document's owner, just as for imposition.
public actor PageThumbnails {
    private struct Key: Hashable {
        let page: Int
        let pixels: Int
    }

    private let source: PDFComposer.Source
    private var document: CGPDFDocument?
    private let limit: Int
    private var images: [Key: (image: CGImage, used: Int)] = [:]
    private var sequence = 0
    public private(set) var byteCount = 0

    @MainActor public init(_ render: PreparedRender, limit: Int = 60 * 1024 * 1024) {
        source = PDFComposer.Source(
            render.viewDocument, bytes: render.viewDocument === render.logicalDocument ? render.sourceBytes : nil)
        self.limit = limit
    }

    public func image(page: Int, pixels: Int) async -> CGImage? {
        guard !Task.isCancelled, page >= 0, (1...1024).contains(pixels) else { return nil }
        let key = Key(page: page, pixels: pixels)
        sequence += 1
        if let entry = images[key] {
            images[key]?.used = sequence
            return entry.image
        }
        let pdf: CGPDFDocument?
        let number: Int
        switch source {
        case .bytes(let data):
            if document == nil { document = Self.open(data) }
            pdf = document
            number = page + 1
        case .edited(let count, let snapshot):
            guard page < count, let data = try? await snapshot(page), !Task.isCancelled else { return nil }
            // Another cell may have finished the same look-ahead request during the actor hop.
            if let entry = images[key] { return entry.image }
            pdf = Self.open(data)
            number = 1
        }
        guard !Task.isCancelled, let sheet = pdf?.page(at: number),
            let image = Self.draw(sheet, pixels: pixels), !Task.isCancelled
        else { return nil }
        let cost = image.bytesPerRow * image.height
        if cost <= limit {
            while byteCount + cost > limit, let oldest = images.min(by: { $0.value.used < $1.value.used }) {
                byteCount -= oldest.value.image.bytesPerRow * oldest.value.image.height
                images.removeValue(forKey: oldest.key)
            }
            images[key] = (image, sequence)
            byteCount += cost
        }
        return image
    }

    private static func open(_ bytes: Data) -> CGPDFDocument? {
        CGDataProvider(data: bytes as CFData).flatMap(CGPDFDocument.init)
    }

    /// The longest edge is bounded even for a panoramic scan. Both appearances use the same opaque paper.
    private static func draw(_ page: CGPDFPage, pixels: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard !box.isEmpty, box.width.isFinite, box.height.isFinite else { return nil }
        let turned = page.rotationAngle % 180 != 0
        let scale = CGFloat(pixels) / max(box.width, box.height)
        let width = max(1, Int(((turned ? box.height : box.width) * scale).rounded()))
        let height = max(1, Int(((turned ? box.width : box.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
