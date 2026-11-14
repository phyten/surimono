import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PageFootnotesPipelineTests {
    private func settings() throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private let markdown = "A reference[^one].\n\n[^one]: A note.\n"

    @Test("脚注設定の変更でキャッシュを更新し測定失敗時は元のHTMLへ戻す")
    func fallbackAndCache() async throws {
        var inputs: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { inputs.append(html) }
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        var options = try settings()
        _ = try await renderer.prepare(source, settings: options)
        let plain = try #require(inputs.last)
        #expect(inputs.count == 1)
        options.finish.footnotes = .pageBottom
        _ = try await renderer.prepare(source, settings: options)
        #expect(inputs.count == 3)
        #expect(inputs[1].contains("<section class=\"paper-footnote-stock\">"))
        #expect(inputs[2] == plain)
        _ = try await renderer.prepare(source, settings: options)
        #expect(inputs.count == 3)
        options.finish.footnotes = .end
        _ = try await renderer.prepare(source, settings: options)
        #expect(inputs.last == plain)
        #expect(inputs.count == 4)
    }

    @Test("測定中のキャンセルは文末へのフォールバックで握りつぶさない")
    func cancellation() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            throw CancellationError()
        })
        var options = try settings()
        options.finish.footnotes = .pageBottom
        do {
            _ = try await renderer.prepare(
                DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: options)
            Issue.record("キャンセルを伝える必要がある")
        } catch is CancellationError {
            #expect(calls == 1)
        }
    }

    @Test("HTMLと合本と表内だけの参照は測定経路へ入らない")
    func excludedDocuments() async throws {
        var inputs: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { inputs.append(html) }
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        var options = try settings()
        options.finish.footnotes = .pageBottom
        let converted = MarkdownConverter.convert(markdown).body
        _ = try await renderer.prepare(DocumentSource(data: Data(converted.utf8), format: .html), settings: options)
        _ = try await renderer.prepare(
            .binder([
                DocumentSource(data: Data(markdown.utf8), format: .markdown),
                DocumentSource(data: Data("Another document".utf8), format: .plainText),
            ]), settings: options)
        let table = "| Header |\n| --- |\n| ref[^one] |\n\n[^one]: A note.\n"
        _ = try await renderer.prepare(DocumentSource(data: Data(table.utf8), format: .markdown), settings: options)
        #expect(inputs.count == 4)
        #expect(inputs.allSatisfy { !$0.contains("<section class=\"paper-footnote-stock\">") })
        #expect(inputs.last?.contains("<section class=\"footnotes\">") == true)
    }
}
