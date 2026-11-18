import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct AsciiDocRenderingTests {
    private func sample() throws -> DocumentSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample.adoc")
        return DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .asciidoc)
    }

    @Test("AsciiDocの印刷要求で図の描画を有効にし文書のスクリプトを無効にする", .timeLimit(.minutes(1)))
    func preparesSample() async throws {
        let source = try sample()
        let html = try #require(await Task.detached { DocumentRenderer.structureHTML(of: source) }.value)
        #expect(
            DocumentOutline.headings(inHTML: html).map(\.text) == [
                "紙の実験 / Paper workshop", "1. 準備 / Setup", "2. 図と数式 / Figures",
            ])
        var prepared = false
        let renderer = DocumentRenderer(paginate: { request in
            prepared = true
            #expect(!request.allowsJavaScript)
            #expect(request.rendersMermaid && request.rendersDiagrams)
            if case .html(let html, let baseURL) = request.source {
                #expect(baseURL == source.fileURL?.deletingLastPathComponent())
                #expect(html.contains("format-asciidoc"))
                #expect(html.contains("data:image/png;base64,"))
            } else {
                Issue.record("AsciiDocをHTMLとして組版する")
            }
            return try RenderingFixtures.pdf()
        })
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        settings.allowsJavaScriptInHTML = true
        _ = try await renderer.render(source, settings: settings)
        #expect(prepared)
    }

    @Test("AsciiDocの実文書を組版し目次の全見出しを紙に対応づける", .timeLimit(.minutes(1)))
    func paginatesSample() async throws {
        _ = NSApplication.shared
        let source = try sample()
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.logicalDocument.pageCount >= 2)
        let html = try #require(DocumentRenderer.structureHTML(of: source))
        let headings = DocumentOutline.headings(inHTML: html)
        #expect(headings.map(\.text) == ["紙の実験 / Paper workshop", "1. 準備 / Setup", "2. 図と数式 / Figures"])
        let texts = (0..<result.logicalDocument.pageCount).map { result.logicalDocument.page(at: $0)?.string ?? "" }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: texts).allSatisfy { $0 != nil })
    }
}
