import AppKit
import CoreText
import ImageIO
import PDFKit
import Testing

@MainActor
enum RenderingFixtures {
    static func pdf(count: Int = 1, size: CGSize = CGSize(width: 612, height: 792)) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<count {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            let text = NSAttributedString(
                string: "PAGE-\(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            context.textPosition = CGPoint(x: 30, y: size.height - 50)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    static func image(orientation: Int = 1, frames: Int = 1) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func pixel(_ page: PDFPage, x: Int, y: Int) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = ((height - 1 - y) * width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
