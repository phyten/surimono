import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXExportPreparationTests {
    @Test(
        "書き出しの組版要求に、表のアクセント数式・スライドの文献・多重リストの末尾が届く",
        .timeLimit(.minutes(1)),
        arguments: ["022-batch-grid", "083-class-beamer", "095-mixed-card"])
    func preparesCorpus(_ name: String) async throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("Snapshots/corpus/latex/\(name)/main.tex")
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        var preparedHTML: String?
        // Capture the export worker's input to pagination, including its normal caller stack.
        let renderer = DocumentRenderer(
            isSandboxed: { false },
            paginate: { request in
                if case .html(let html, _) = request.source { preparedHTML = html }
                return try RenderingFixtures.pdf()
            })
        _ = try await renderer.prepare(source, settings: settings)
        let html = try #require(preparedHTML)
        switch name {
        case "022-batch-grid":
            #expect(html.contains(#"aria-label="\bar{x}""#))
            #expect(!html.contains(#"<code class="math-error">"#))
        case "083-class-beamer":
            #expect(html.contains("Spacer register"))
        default:
            #expect(html.contains("Folded strip"))
        }
    }
}
