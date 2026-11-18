import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.serialized)
@MainActor
struct ComputationalRenderingTests {
    @Test("QuartoとR Markdownの見本を実際に組版し紙に未実行注記を残す", .timeLimit(.minutes(1)), arguments: ["qmd", "Rmd"])
    func paginates(suffix: String) async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Samples/sample." + suffix)
        let source = DocumentSource(
            data: try Data(contentsOf: url), fileURL: url,
            format: try #require(DocumentFormat(fileExtension: suffix)))
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(source, settings: settings)
        let pdf = result.logicalDocument
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
            .filter { !$0.isWhitespace }
        #expect(pdf.pageCount >= 2)
        #expect(text.contains(suffix == "qmd" ? "結果は表示されません" : "Resultsareunavailable"))
        #expect(text.contains(suffix == "qmd" ? "観察点" : "Measuredwidths"))
        #expect(!text.contains("opts_chunk"))
    }
}
