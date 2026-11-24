import AppKit
import CoreText
import ImageIO
import PDFKit
import Testing
import WebKit

@MainActor
enum RenderingFixtures {
    static func clearBackground() throws -> @MainActor (WKWebView) -> Void {
        try #require(WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:")))
        return { $0.setValue(false, forKey: "drawsBackground") }
    }

    static func latinSummary(_ json: String) -> String {
        guard let report = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return json
        }
        let skipped = (report["skipped"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        let fallbacks = (report["paragraphs"] as? [[String: Any]] ?? []).compactMap { $0["fallback"] as? String }
        let style = (report["firstSkippedStyle"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return
            "qualifying=\(report["qualifying"] ?? "?") composed=\(report["composed"] ?? "?") fallbacks=\(report["fallbacks"] ?? "?") \(Set(fallbacks).sorted()) skipped=\(Set(skipped).sorted()) firstException=\(report["firstException"] ?? "none")"
            + (style.isEmpty ? "" : " CSS[\(style)]")
    }

    static func pdf(
        count: Int = 1, size: CGSize = CGSize(width: 612, height: 792), textPrefix: String = "PAGE-"
    ) throws -> PDFDocument {
        // A prefix may hold several lines; these pages keep the 25 pt spacing their tests were written for.
        try pdf(
            pages: (0..<count).map { "\(textPrefix)\($0 + 1)".components(separatedBy: "\n") }, size: size,
            lineSpacing: 25)
    }

    static func pdf(
        pages: [[String]], size: CGSize = CGSize(width: 612, height: 792), lineSpacing: CGFloat = 30
    ) throws -> PDFDocument {
        try #require(PDFDocument(data: try pdfData(pages: pages, size: size, lineSpacing: lineSpacing)))
    }

    // Author source bookmarks in Quartz so a reader test doesn't first depend on PDFKit's writer.
    static func pdfData(
        count: Int, size: CGSize = CGSize(width: 612, height: 792), textPrefix: String = "PAGE-",
        bookmarks: [(String, Int)] = []
    ) throws -> Data {
        try pdfData(
            pages: (0..<count).map { "\(textPrefix)\($0 + 1)".components(separatedBy: "\n") }, size: size,
            lineSpacing: 25, bookmarks: bookmarks)
    }

    static func pdfData(
        pages: [[String]], size: CGSize = CGSize(width: 612, height: 792), lineSpacing: CGFloat = 30,
        bookmarks: [(String, Int)] = [], font: NSFont = .systemFont(ofSize: 20)
    ) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            for (index, line) in lines.enumerated() {
                let text = NSAttributedString(string: line, attributes: [.font: font])
                context.textPosition = CGPoint(x: 30, y: size.height - 50 - CGFloat(index) * lineSpacing)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        if !bookmarks.isEmpty {
            let children: [[String: Any]] = bookmarks.map {
                [kCGPDFOutlineTitle as String: $0.0, kCGPDFOutlineDestination as String: $0.1]
            }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        }
        context.closePDF()
        return data as Data
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

    /// The columns of a page that hold anything darker than the paper.
    static func inkColumns(_ page: PDFPage) throws -> ClosedRange<Int> {
        let bounds = try #require(try inkBounds(page))
        return Int(bounds.minX)...(Int(bounds.maxX) - 1)
    }

    /// One bitmap pixel per PDF point, independent of the runner's display.
    static func inkBounds(_ page: PDFPage) throws -> CGRect? {
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
        var left = width
        var right = -1
        var bottom = height
        var top = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4] < 200 {
                left = min(left, x)
                right = max(right, x)
                bottom = min(bottom, y)
                top = y
            }
        }
        guard right >= left else { return nil }
        return CGRect(x: left, y: bottom, width: right - left + 1, height: top - bottom + 1)
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
