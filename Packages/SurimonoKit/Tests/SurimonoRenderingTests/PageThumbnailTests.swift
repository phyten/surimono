import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PageThumbnailTests {
    @Test("縮図は用紙の縦横比を保ち、上限を超えると古い寸法を捨てる")
    func boundedCache() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let consumer = try #require(CGDataConsumer(data: data))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for color in [
            CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        ] {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(color)
            pdf.fill(box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "standard", name: "", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let render = try await DocumentRenderer().prepare(
            DocumentSource(data: data as Data, format: .pdf), settings: settings)
        let cache = PageThumbnails(render, limit: 8192)
        let first = try #require(await cache.image(page: 0, pixels: 64))
        #expect(first.width == 64 && first.height == 32)
        let hit = try #require(await cache.image(page: 0, pixels: 64))
        #expect(first === hit)
        let hovered = try #require(await cache.scrubImage(page: 0, pixels: 64))
        #expect(first === hovered)
        let second = try #require(await cache.image(page: 1, pixels: 64))
        let blue = try centerColor(second)
        #expect(blue.blueComponent > 0.9 && blue.redComponent < 0.1 && blue.greenComponent < 0.1)
        #expect(await cache.byteCount <= 8192)
        let again = try #require(await cache.image(page: 0, pixels: 64))
        #expect(first !== again)
        for image in [first, again] {
            let red = try centerColor(image)
            #expect(red.redComponent > 0.9 && red.greenComponent < 0.1 && red.blueComponent < 0.1)
        }
        #expect(await cache.image(page: 2, pixels: 64) == nil)
    }

    private func centerColor(_ image: CGImage) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try #require(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.sRGB))
    }
}
