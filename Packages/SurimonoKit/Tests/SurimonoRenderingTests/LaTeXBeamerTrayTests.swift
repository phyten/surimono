import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXBeamerTrayTests {
    @Test("読む PDF はスライド寸法のまま、書き込み用の三面には選んだスライドを載せる", .timeLimit(.minutes(1)))
    func slideSelectionAndStock() async throws {
        let tex = #"""
            \documentclass[aspectratio=169]{beamer}
            \begin{document}
            \section{Morning}
            \frame{Copper float}
            \section{Afternoon}
            \frame<0>{Unused float}
            \frame{Tin float}
            \frame{Zinc float}
            \end{document}
            """#
        let source = DocumentSource(data: Data(tex.utf8), fileURL: nil, format: .latex)
        let renderer = DocumentRenderer()
        let themeID = PrintThemeLibrary.defaultLaTeXStyle(for: renderer.latexClassInfo(for: source))
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == themeID })
        var settings = RenderSettings(layout: .a4Handout3, theme: theme, preset: .init(id: "none", name: ""))
        let deck = try await renderer.prepare(source, settings: settings)
        let page = try #require(deck.viewDocument.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 453.543) < 0.02)
        #expect(abs(bounds.height - 255.118) < 0.02)
        let outline = await ReadingPDFExporter.outline(
            of: source, in: deck.viewDocument, proof: settings.finish.proof, includesSourceContents: true,
            facts: deck.facts)
        #expect(outline.entries.map(\.pageIndex) == [0, 1])
        let reading = try await ReadingPDFExporter.document(
            from: deck.viewDocument, entries: outline.entries, title: "Floats")
        #expect(reading.pageCount == 3)
        #expect(reading.outlineRoot?.numberOfChildren == 2)

        settings.slides = SlidePrintRequest(slideSize: bounds.size, count: 3, onlyIndex: 1)
        let tray = try await renderer.render(source, settings: settings)
        #expect(tray.pageSelection.pages == [1])
        #expect(tray.sheetDocument.pageCount == 1)
        let sheet = try #require(tray.sheetDocument.page(at: 0))
        let size = sheet.bounds(for: .mediaBox).size
        #expect(abs(min(size.width, size.height) - 595.276) < 0.1)
        #expect(abs(max(size.width, size.height) - 841.890) < 0.1)
        let text = try #require(sheet.string)
        #expect(text.contains("Tin float"))
        #expect(!text.contains("Copper") && !text.contains("Zinc"))
    }
}
