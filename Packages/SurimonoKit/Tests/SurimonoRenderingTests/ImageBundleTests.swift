import AppKit
import ImageIO
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ImageBundleTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func image(_ name: String, color: (CGFloat, CGFloat, CGFloat)) throws -> DocumentSource.Image {
        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return DocumentSource.Image(data: data as Data, fileURL: URL(fileURLWithPath: "/fixtures/" + name))
    }

    private func colors(_ document: PDFDocument) throws -> [[UInt8]] {
        try (0..<document.pageCount).map {
            let page = try #require(document.page(at: $0))
            let pixel = try RenderingFixtures.pixel(page, x: 297, y: 420)
            // Color management can shift channel values slightly; the dominant primary identifies the page.
            return Array(pixel.prefix(3)).map { $0 > 200 ? 255 : 0 }
        }
    }

    @Test("3枚の画像を並び順どおりに3ページにし並び替えで再描画する")
    func order() async throws {
        let images = try [
            image("red.png", color: (1, 0, 0)), image("green.png", color: (0, 1, 0)),
            image("blue.png", color: (0, 0, 1)),
        ]
        let renderer = DocumentRenderer()
        let first = try await renderer.render(.images(images), settings: settings)
        #expect(first.logicalDocument.pageCount == 3)
        #expect(try colors(first.logicalDocument) == [[255, 0, 0], [0, 255, 0], [0, 0, 255]])
        let reordered = try await renderer.render(.images([images[2], images[0], images[1]]), settings: settings)
        #expect(try colors(reordered.logicalDocument) == [[0, 0, 255], [255, 0, 0], [0, 255, 0]])
        #expect(try colors(reordered.sheetDocument) == [[0, 0, 255], [255, 0, 0], [0, 255, 0]])
        #expect(renderer.logicalRenderCount == 2)
        var duplex = settings
        duplex.layout = .a4Duplex
        duplex.options.showsPageNumbers = true
        duplex.options.rotatesBackSides = true
        _ = try await renderer.render(.images([images[2], images[0], images[1]]), settings: duplex)
        #expect(renderer.logicalRenderCount == 2)
    }

    @Test("同じURLの画像データを変更してもキャッシュを再利用しない")
    func changedContents() async throws {
        let renderer = DocumentRenderer()
        let red = try image("same.png", color: (1, 0, 0))
        let blue = try image("same.png", color: (0, 0, 1))
        _ = try await renderer.render(.images([red]), settings: settings)
        let result = try await renderer.render(.images([blue]), settings: settings)
        #expect(try colors(result.logicalDocument) == [[0, 0, 255]])
        #expect(renderer.logicalRenderCount == 2)
    }

    @Test("5枚の画像はA3中綴じで2枚4面になる")
    func booklet() async throws {
        var settings = settings
        settings.layout = .a3BookletA4
        let images = try (1...5).map { try image("\($0).png", color: (1, 0, 0)) }
        let result = try await DocumentRenderer().render(.images(images), settings: settings)
        #expect(result.summary.logicalPageCount == 5)
        #expect(result.summary.paper == .a3)
        #expect(result.summary.sheetCount == 2)
        #expect(result.sheetDocument.pageCount == 4)
    }

    @Test("読めない画像を飛ばして名前を返しキャッシュ再利用後も保持する")
    func unreadable() async throws {
        let bad = DocumentSource.Image(data: Data(), fileURL: URL(fileURLWithPath: "/fixtures/broken.png"))
        let good = try image("good.png", color: (1, 0, 0))
        let renderer = DocumentRenderer()
        for _ in 0..<2 {
            let result = try await renderer.render(.images([bad, good]), settings: settings)
            #expect(result.logicalDocument.pageCount == 1)
            #expect(result.unreadableImageURLs == [bad.fileURL])
        }
        #expect(renderer.logicalRenderCount == 1)
        await #expect(throws: DocumentRenderer.RenderingError.noReadableImages([bad.fileURL])) {
            _ = try await renderer.render(.images([bad]), settings: settings)
        }
    }
}
