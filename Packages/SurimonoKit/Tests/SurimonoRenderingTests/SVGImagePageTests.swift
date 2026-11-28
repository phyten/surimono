import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct SVGImagePageTests {
    private let wide = Data(
        ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#f00"/></svg>"##
            .utf8)
    private let viewBoxOnly = Data(
        ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 300"><rect width="100" height="300" fill="#00f"/></svg>"##
            .utf8)
    // The root element is complete, so the file is an SVG, but the markup after it is broken.
    private let broken = Data(
        #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40"</svg"#.utf8)

    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("横長の SVG を画像として開くと、横向きの A4 の 1 ページに収まる", .timeLimit(.minutes(1)))
    func singleSVG() async throws {
        let result = try await DocumentRenderer().render(DocumentSource(data: wide, format: .image), settings: settings)
        let page = try #require(result.logicalDocument.page(at: 0))
        #expect(result.logicalDocument.pageCount == 1)
        let paper = page.bounds(for: .mediaBox).size
        #expect(abs(paper.width - 841.89) < 0.01 && abs(paper.height - 595.28) < 0.01)
        let art = page.bounds(for: .artBox)
        // Landscape A4 less 15 mm on each side is 756.9 pt wide; a 2:1 image fills that width.
        #expect(abs((art.width - 2 * 42.52) - 756.85) < 1)
        #expect(abs((art.height - 2 * 42.52) - 378.43) < 1)
    }

    @Test("SVG のページは画素ではなく図形で描く", .timeLimit(.minutes(1)))
    func vector() async throws {
        let document = try await ImagePageRenderer().render(wide, pageSize: PaperSize.a4.size)
        let page = try #require(document.page(at: 0))
        // The red fill covers the middle of the portrait page.
        let pixel = try RenderingFixtures.pixel(page, x: 297, y: 421)
        #expect(pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60)
        let data = try #require(document.dataRepresentation())
        // A page drawn from pixels carries an image XObject; this one carries only paths.
        #expect(!String(decoding: data, as: UTF8.self).contains("/Subtype /Image"))
    }

    @Test("viewBox だけの SVG は viewBox の縦横比のページになる", .timeLimit(.minutes(1)))
    func viewBox() async throws {
        let document = try await ImagePageRenderer().render(viewBoxOnly, pageSize: PaperSize.a4.size)
        let page = try #require(document.page(at: 0))
        let art = page.bounds(for: .artBox)
        let ratio = (art.height - 2 * 42.52) / (art.width - 2 * 42.52)
        #expect(abs(ratio - 3) < 0.05)
    }

    @Test("SVG の寸法は画像の寸法として読み、横長なら用紙を横にする")
    func contentSize() throws {
        #expect(try ImagePageRenderer.contentSize(wide) == CGSize(width: 200, height: 100))
    }

    @Test("壊れた SVG は時間内に読めない画像のエラーを返す", .timeLimit(.minutes(1)))
    func brokenSVG() async throws {
        await #expect(throws: ImagePageRenderer.RenderingError.invalidImage) {
            _ = try await ImagePageRenderer().render(broken, pageSize: PaperSize.a4.size)
        }
    }

    @Test("画像の束の SVG はページになり、壊れた SVG だけを読めない画像として返す", .timeLimit(.minutes(1)))
    func bundle() async throws {
        let images = [
            DocumentSource.Image(data: try RenderingFixtures.image(), fileURL: URL(fileURLWithPath: "/fixtures/1.png")),
            DocumentSource.Image(data: wide, fileURL: URL(fileURLWithPath: "/fixtures/2.svg")),
            DocumentSource.Image(data: broken, fileURL: URL(fileURLWithPath: "/fixtures/3.svg")),
            DocumentSource.Image(data: viewBoxOnly, fileURL: URL(fileURLWithPath: "/fixtures/4.svg")),
        ]
        let result = try await DocumentRenderer().render(.images(images), settings: settings)
        #expect(result.logicalDocument.pageCount == 3)
        #expect(result.unreadableImageURLs == [URL(fileURLWithPath: "/fixtures/3.svg")])
    }
}
