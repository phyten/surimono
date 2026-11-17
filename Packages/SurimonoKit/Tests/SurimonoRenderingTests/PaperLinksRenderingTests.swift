import Foundation
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PaperLinksRenderingTests {
    @Test("テーマ文書のリンク設定は組版の直前に効きHTML文書には効かない", .timeLimit(.minutes(1)))
    func destinationsReachPagination() async throws {
        let themes = try PrintThemeLibrary.load()
        var options = RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        options.finish.links = .endnotes
        options.pageLanguage = "ja"
        var inputs: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { inputs.append(html) }
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        _ = try await renderer.prepare(
            DocumentSource(data: Data("[参照](https://example.test)".utf8), format: .markdown), settings: options)
        #expect(inputs.contains { $0.contains("class=\"paper-link-ref\">[1]</sup>") && $0.contains(">リンク</h2>") })
        inputs = []
        options.pageLanguage = "fr"
        _ = try await renderer.prepare(
            DocumentSource(data: Data("[参照](https://example.test)".utf8), format: .markdown), settings: options)
        #expect(inputs.contains { $0.contains(">Liens</h2>") })
        inputs = []
        _ = try await renderer.prepare(
            DocumentSource(data: Data("<a href='https://example.test'>参照</a>".utf8), format: .html), settings: options)
        #expect(!inputs.isEmpty)
        #expect(inputs.allSatisfy { !$0.contains("class=\"paper-link-ref\"") })
    }

    @Test("前付けとノートを挿入しても柱の章は本文のページに対応する", .timeLimit(.minutes(1)))
    func chapterFurnitureOnFinishedPages() async throws {
        let themes = try PrintThemeLibrary.load()
        var options = RenderSettings(
            layout: .a4Duplex, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        options.finish.toc.mode = .front
        options.options.furniture.topCenter = "CHAPTER:{章}"
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source, html.contains("paper-toc-title") {
                return try RenderingFixtures.pdf(size: request.pageSize)
            }
            return try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let source = DocumentSource(data: Data("# PAGE-1\n\n# PAGE-2\n".utf8), format: .markdown)
        let result = try await renderer.render(source, settings: options)
        #expect(result.logicalDocument.pageCount == 3)
        #expect(result.sheetDocument.pageCount == 4)
        #expect(result.sheetDocument.page(at: 0)?.string?.contains("CHAPTER:PAGE-") == false)
        #expect(result.sheetDocument.page(at: 1)?.string?.contains("CHAPTER:PAGE-1") == true)
        #expect(result.sheetDocument.page(at: 2)?.string?.contains("CHAPTER:PAGE-2") == true)
        options.notes = NotePages(isEnabled: true, placement: .chapterEnd)
        let noted = try await renderer.render(source, settings: options)
        #expect(noted.logicalDocument.pageCount == 5)
        #expect(noted.sheetDocument.page(at: 1)?.string?.contains("CHAPTER:PAGE-1") == true)
        #expect(noted.sheetDocument.page(at: 2)?.string?.contains("CHAPTER:") != true)
        #expect(noted.sheetDocument.page(at: 3)?.string?.contains("CHAPTER:PAGE-2") == true)
        #expect(noted.sheetDocument.page(at: 4)?.string?.contains("CHAPTER:") != true)
    }
}
