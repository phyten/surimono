import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct SmartRemovalRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), smartRemoval: SmartRemovalRequest())
    }

    @Test("HTMLの候補はPDFと一緒にキャッシュされ印刷だけの変更では検出し直さない")
    func cachedCandidates() async throws {
        var calls = 0
        let candidate = SmartRemovalCandidate(id: "#ad", category: .advertisement, excerpt: "Ad", reason: "class=ad")
        let json = String(decoding: try JSONEncoder().encode([candidate]), as: UTF8.self)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            calls += 1
            #expect(request.preparationScript?.contains("const request = ") == true)
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: json)
        })
        let source = DocumentSource(data: Data("<p>Article</p>".utf8), format: .html)
        let first = try await renderer.render(source, settings: settings)
        var changed = settings
        changed.options.showsPageNumbers = true
        let second = try await renderer.render(source, settings: changed)
        #expect(first.smartRemovalCandidates == [candidate])
        #expect(second.smartRemovalCandidates == [candidate])
        #expect(calls == 1)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("HTMLの有効状態と残す選択と確認モードを変えると組版し直す")
    func invalidatesCache() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginateWithResult: { _ in
            calls += 1
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: "[]")
        })
        let source = DocumentSource(data: Data("<p>Article</p>".utf8), format: .html)
        var changed = settings
        _ = try await renderer.render(source, settings: changed)
        changed.smartRemoval?.keptIDs = ["#ad"]
        _ = try await renderer.render(source, settings: changed)
        changed.smartRemoval?.highlightsCandidates = true
        _ = try await renderer.render(source, settings: changed)
        changed.smartRemoval = nil
        let result = try await renderer.render(source, settings: changed)
        #expect(result.smartRemovalCandidates == [])
        #expect(calls == 4)
    }

    @Test("HTML以外ではスマート除去を実行せずキャッシュキーにも含めない")
    func ignoresOtherFormats() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            calls += 1
            // Only the question whether the theme has paper, which every themed page asks.
            #expect(request.preparationScript == nil || request.preparationScript == PaperBackground.detectionScript)
            return WebPaginator.Result(
                document: try RenderingFixtures.pdf(),
                preparationResult: ##"[{"id":"#ad","category":"advertisement","excerpt":"Ad","reason":"ad"}]"##)
        })
        let source = DocumentSource(data: Data("Text".utf8), format: .plainText)
        var changed = settings
        let first = try await renderer.render(source, settings: changed)
        changed.smartRemoval = nil
        let second = try await renderer.render(source, settings: changed)
        #expect(first.smartRemovalCandidates == [])
        #expect(second.smartRemovalCandidates == [])
        #expect(calls == 1)
    }

    @Test("既存のPDFだけを返す組版フックをそのまま使える")
    func legacyHook() async throws {
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let result = try await renderer.render(
            DocumentSource(data: Data("<p>Article</p>".utf8), format: .html), settings: settings)
        #expect(result.smartRemovalCandidates == [])
        #expect(result.logicalDocument.pageCount == 1)
    }

    @Test("プリセット、スマート除去、紙面の整えの順に実行し、スマート除去の結果を返す")
    func presetOrder() async throws {
        var changed = settings
        changed.preset.removeSelectors = [".preset-only"]
        let expected =
            HTMLCleanupScript.javaScript(for: changed.preset) + "\n"
            + PaperCleanupScript.following(SmartRemovalScript.javaScript(for: SmartRemovalRequest()))
        let renderer = DocumentRenderer(paginateWithResult: { request in
            #expect(request.preparationScript == expected)
            #expect(!request.allowsJavaScript)
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: "invalid")
        })
        let result = try await renderer.render(
            DocumentSource(data: Data("<p>Article</p>".utf8), format: .html), settings: changed)
        #expect(result.smartRemovalCandidates == [])
    }
}
