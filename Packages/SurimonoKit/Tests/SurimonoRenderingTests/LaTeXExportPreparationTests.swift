import PDFKit
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
            paginateWithResult: { request in
                if case .html(let html, _) = request.source { preparedHTML = html }
                // The slide renderer consumes the frame-to-page map measured by WebKit.
                if name == "083-class-beamer" { return try await WebPaginator().paginate(request) }
                return WebPaginator.Result(document: try RenderingFixtures.pdf())
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

    @Test(
        "NeurIPS 原稿の読むための PDF を開き直すと、本文の引用から同じ参考文献の位置へ移れる",
        .timeLimit(.minutes(1)), arguments: ["113-style-neurips", "114-style-neurips-final"])
    func neuripsReadingPDF(_ name: String) async throws {
        let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let url = root.appendingPathComponent("Snapshots/corpus/latex/\(name)/main.tex")
        let source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        try #require(!prepared.issues.contains { $0.id == "latex-flow-fallback" })
        let view = prepared.viewDocument
        let outline = await ReadingPDFExporter.outline(
            of: source, in: view, proof: settings.finish.proof, includesSourceContents: false, facts: prepared.facts)
        let data = try await ReadingPDFExporter.data(
            from: view, entries: outline.entries, title: outline.title ?? name, headings: outline.headings,
            sourceURL: url, furniture: prepared.viewFurniture)
        let saved = try #require(PDFDocument(data: data))
        func citation(in document: PDFDocument) throws -> CGPoint {
            try #require(document.pageCount == 3)
            let annotation = try #require(document.page(at: 0)?.annotations.first)
            let dest = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
            let page = try #require(dest.page)
            #expect(page === document.page(at: 2))
            let entry = try #require(document.findString("Model Rail Desk. 2025.").first)
            try #require(entry.pages.first === page)
            let line = entry.bounds(for: page)
            #expect(abs(dest.point.x - line.minX) < 6 && abs(dest.point.y - line.maxY) < 6)
            return dest.point
        }
        let original = try citation(in: view)
        let reopened = try citation(in: saved)
        #expect(abs(original.x - reopened.x) < 0.001 && abs(original.y - reopened.y) < 0.001)
    }
}
