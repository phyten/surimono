import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct NotebookRenderingTests {
    private func sample() throws -> DocumentSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample.ipynb")
        return DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .notebook)
    }

    @Test("Notebookの実パイプラインで保存済み出力と目次を組版する", .timeLimit(.minutes(1)))
    func paginatesSample() async throws {
        _ = NSApplication.shared
        let source = try sample()
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.logicalDocument.pageCount > 0)
        let html = try #require(DocumentRenderer.structureHTML(of: source))
        let headings = DocumentOutline.headings(inHTML: html)
        #expect(headings.map(\.text) == ["保存した実験ノート", "計算 / Calculation", "図と表 / Results", "エラーと対話型出力 / Diagnostics"])
        let texts = (0..<result.logicalDocument.pageCount).map { result.logicalDocument.page(at: $0)?.string ?? "" }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: texts).allSatisfy { $0 != nil })
        #expect(result.logicalDocument.string?.contains("Apple") == true)
        #expect(result.logicalDocument.string?.contains("ZeroDivisionError") == true)
    }

    @Test("Notebookはテーマとコードオプションを使い文書のJavaScriptを無効にする")
    func pipeline() async throws {
        let source = try sample()
        var observed = false
        let renderer = DocumentRenderer(paginate: { request in
            observed = true
            #expect(!request.allowsJavaScript)
            if case .html(let html, let base) = request.source {
                #expect(base == source.fileURL?.deletingLastPathComponent())
                #expect(html.contains("format-notebook"))
                #expect(html.contains("code-block"))
                #expect(html.contains("data:image/png;base64,"))
            } else {
                Issue.record("NotebookをHTMLとして組版する")
            }
            return try RenderingFixtures.pdf()
        })
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        settings.allowsJavaScriptInHTML = true
        settings.code = CodeStyle(block: .init(lineNumbers: .all, languageLabel: .corner))
        _ = try await renderer.render(source, settings: settings)
        #expect(observed)
    }
}
