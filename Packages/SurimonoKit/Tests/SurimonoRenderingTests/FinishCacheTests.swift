import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// The tray's axes against the renderer's caches: what must lay the text out again, and what only composes the sheets.
@MainActor
struct FinishCacheTests {
    private let source = DocumentSource(data: Data("# 一\n\n本文\n\n# 二\n\n本文\n".utf8), format: .markdown)

    private func settings(_ layout: PrintLayout = .a4Duplex) throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: layout, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func renderer() -> DocumentRenderer {
        DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf(count: 2) })
    }

    @Test("ヘッダーを変えても文書は組み直さず、用紙だけ作り直す")
    func headerComposesOnly() async throws {
        var settings = try settings()
        let renderer = renderer()
        _ = try await renderer.render(source, settings: settings)
        settings.options.furniture = .name
        _ = try await renderer.render(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 2)
    }

    @Test("改ページ・目次・コードの配色・判は、それぞれ文書を組み直す")
    func layoutAxes() async throws {
        var settings = try settings()
        let renderer = renderer()
        _ = try await renderer.prepare(source, settings: settings)
        settings.finish.breaks.h1 = .page
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 2)
        settings.finish.toc.mode = .front
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 3)
        settings.code.block.lineNumbers = .all
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 4)
        settings.layout = .b5Duplex
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 5)
    }

    @Test("A判へ戻すと A判の大きさで組み直し、目次と改ページはそのまま効く")
    func seriesKeepsFinish() async throws {
        var settings = try settings()
        settings.finish.toc.mode = .front
        settings.finish.breaks.h1 = .rightPage
        var sizes: [CGSize] = []
        let renderer = DocumentRenderer(paginate: { request in
            sizes.append(request.pageSize)
            return try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let a = try await renderer.prepare(source, settings: settings)
        settings.layout = .b5Duplex
        let b = try await renderer.prepare(source, settings: settings)
        // The stand-in lays every text out on two pages, the contents too.
        #expect(a.addedContentsPages == 2)
        #expect(b.addedContentsPages == 2)
        #expect(sizes.contains(PrintLayout.a4Duplex.logicalPageSize))
        #expect(sizes.contains(PrintLayout.b5Duplex.logicalPageSize))
        let width = try #require(b.logicalDocument.page(at: 0)).bounds(for: .mediaBox).width
        #expect(abs(width - PrintLayout.b5Duplex.logicalPageSize.width) < 1)
    }

    @Test("ヘッダーと改ページと目次と配色と判とノートをまとめて文書の記録に残せる")
    func everyAxisInTheRecord() throws {
        var options = PrintOptions()
        options.furniture = .nameAndDate
        var finish = PrintFinish()
        finish.breaks.h1 = .rightPage
        finish.toc.mode = .front
        var block = CodeBlockOptions()
        block.lineNumbers = .everyFive
        let saved = DocumentSettings(
            layoutID: "b5Duplex", printOptions: options, printFinish: finish, codePaletteID: "ink", codeBlock: block,
            paperSeries: .b, notes: NotePages(isEnabled: true))
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }
}
