import CoreGraphics
import ImageIO
import PDFKit
import Testing

@testable import SurimonoRendering

@MainActor
struct PageImageExporterTests {
    @Test("PNGは解像度に応じた寸法で白い紙を描く")
    func dimensions() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 72, height: 36), for: .mediaBox)
        for dpi in [72.0, 144.0] {
            let image = try PageImageExporter.image(page, dpi: dpi)
            #expect(image.width == Int(dpi))
            #expect(image.height == Int(dpi / 2))
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            let png = try PageImageExporter.png(page, dpi: dpi)
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == Int(dpi))
            #expect(decoded.height == Int(dpi / 2))
            let bytes = try #require(image.dataProvider?.data)
            let pointer = try #require(CFDataGetBytePtr(bytes))
            #expect(pointer[0] == 255 && pointer[1] == 255 && pointer[2] == 255)
        }
    }

    @Test("144dpiではPDFの中身も二倍の画素数で描く")
    func contentScale() throws {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 72, height: 36)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 18, height: 36))
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        let image = try PageImageExporter.image(page, dpi: 144)
        let bytes = try #require(image.dataProvider?.data)
        let pointer = try #require(CFDataGetBytePtr(bytes))
        let redPixel = 20 * image.bytesPerRow + 30 * 4
        #expect(
            pointer[redPixel] == 255 && pointer[redPixel + 1] == 0,
            "RGBA: \(Array(UnsafeBufferPointer(start: pointer + redPixel, count: 4)))")
        let whitePixel = 20 * image.bytesPerRow + 60 * 4
        #expect(pointer[whitePixel] == 255 && pointer[whitePixel + 1] == 255)
    }

    @Test("回転とクロップを反映し巨大なページを制限する")
    func rotationAndLimit() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 80), for: .mediaBox)
        page.setBounds(CGRect(x: 10, y: 10, width: 72, height: 36), for: .cropBox)
        page.rotation = 90
        let image = try PageImageExporter.image(page, dpi: 144)
        #expect(image.width == 72)
        #expect(image.height == 144)
        #expect(PageImageExporter.effectiveDPI(size: CGSize(width: 7200, height: 3600), dpi: 300) == 120)
    }
}
