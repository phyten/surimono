import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.serialized)
@MainActor
struct DjotTextileRenderingTests {
    private func sample(_ format: DocumentFormat) throws -> DocumentSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: format == .djot ? "Samples/sample.dj" : "Samples/sample.textile")
        return DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: format)
    }

    @Test("DjotとTextileの見本を組版し見出しを紙に対応づける", .timeLimit(.minutes(1)), arguments: [DocumentFormat.djot, .textile])
    func paginatesSample(format: DocumentFormat) async throws {
        _ = NSApplication.shared
        let source = try sample(format)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        #expect(result.logicalDocument.pageCount >= 1)
        let html = try #require(DocumentRenderer.structureHTML(of: source))
        let headings = DocumentOutline.headings(inHTML: html)
        #expect(headings.map(\.text) == ["紙の実験 / Paper workshop", "準備 / Setup"])
        let texts = (0..<result.logicalDocument.pageCount).map { result.logicalDocument.page(at: $0)?.string ?? "" }
        #expect(DocumentOutline.pages(of: headings, inPageTexts: texts).allSatisfy { $0 != nil })
    }
}

extension DjotTextileRenderingTests {
    @Test("Textile の略語の展開語は紙に括弧で添える", .timeLimit(.minutes(1)))
    func acronymExpansion() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(data: Data("和文の PIM(Paper Index Mark) を読む。".utf8), format: .textile)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        let text = result.logicalDocument.page(at: 0)?.string ?? ""
        #expect(text.contains("PIM（Paper Index Mark）"), "\(text)")
    }
}
