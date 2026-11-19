import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct LaTeXBindingMarginsTests {
    @Test("片面の用紙でも文書指定の内外余白は偶数ページで入れ替わり、手動余白を選ぶと固定される", arguments: [true, false])
    func simplexPages(documentMargins: Bool) async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[a4paper,twoside]{article}
                \usepackage[inner=10mm,outer=20mm]{geometry}
                \begin{document}Odd\newpage Even\end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        if !documentMargins {
            settings.options.latexMargins = nil
            settings.options.margins = PageMargins(top: 12, left: 7, bottom: 12, right: 27)
            settings.options.mirrorsMargins = true
        }
        let renderer = DocumentRenderer(paginate: { request in
            #expect(abs(request.margins.left - (documentMargins ? 10.0 : 7.0) * 72 / 25.4) < 0.01)
            #expect(abs(request.margins.right - (documentMargins ? 20.0 : 27.0) * 72 / 25.4) < 0.01)
            return try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let result = try await renderer.render(source, settings: settings)
        for document in [result.logicalDocument, result.sheetDocument] {
            #expect(document.pageCount == 2)
            let odd = try #require(document.page(at: 0))
            let even = try #require(document.page(at: 1))
            // The injected pages have identical 12 pt squares. A 10 mm shift puts the even square over x = 34.
            #expect(try RenderingFixtures.pixel(odd, x: 5, y: 5)[0] < 60)
            #expect(try RenderingFixtures.pixel(odd, x: 34, y: 5)[0] > 200)
            #expect(try (RenderingFixtures.pixel(even, x: 5, y: 5)[0] < 60) == !documentMargins)
            #expect(try (RenderingFixtures.pixel(even, x: 34, y: 5)[0] < 60) == documentMargins)
        }
    }
}
