import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PageThumbnailTests {
    @Test("縮図は用紙の縦横比を保ち、上限を超えると古い寸法を捨てる")
    func boundedCache() async throws {
        let pdf = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 200, height: 100))
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "standard", name: "", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let render = try await DocumentRenderer().prepare(
            DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf), settings: settings)
        let cache = PageThumbnails(render, limit: 8192)
        let first = try #require(await cache.image(page: 0, pixels: 64))
        #expect(first.width == 64 && first.height == 32)
        let hit = await cache.image(page: 0, pixels: 64)
        #expect(first === hit)
        let hovered = await cache.scrubImage(page: 0, pixels: 64)
        #expect(first === hovered)
        _ = try #require(await cache.image(page: 1, pixels: 64))
        #expect(await cache.byteCount <= 8192)
        let again = await cache.image(page: 0, pixels: 64)
        #expect(first !== again)
        #expect(await cache.image(page: 2, pixels: 64) == nil)
    }
}
