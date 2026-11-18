import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.serialized)
@MainActor
struct MediaWikiRenderingTests {
    private func sample() throws -> DocumentSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample.mediawiki")
        return DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .mediawiki)
    }

    @Test("MediaWikiの見本を組版し見出しを紙に対応づける", .timeLimit(.minutes(1)))
    func paginatesSample() async throws {
        _ = NSApplication.shared
        let source = try sample()
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.logicalDocument.pageCount >= 1)
        let html = try #require(DocumentRenderer.structureHTML(of: source))
        let headings = DocumentOutline.headings(inHTML: html)
        #expect(headings.map(\.text) == ["紙の試験室 / Paper workshop", "観察", "記録"])
        let texts = (0..<result.logicalDocument.pageCount).map { result.logicalDocument.page(at: $0)?.string ?? "" }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: texts).allSatisfy { $0 != nil })
    }
}
