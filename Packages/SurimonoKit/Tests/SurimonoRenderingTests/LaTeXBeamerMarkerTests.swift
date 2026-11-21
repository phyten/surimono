import PDFKit
import SurimonoCore
import SurimonoFormats
import SurimonoRendering
import Testing

@MainActor
struct LaTeXBeamerMarkerTests {
    @Test("文献の記号を切り替えたときも本文を実 TeX と同じ左端にそろえる", .timeLimit(.minutes(1)))
    func bibliographyMarkers() async throws {
        let tex = #"""
            \documentclass{beamer}
            \begin{document}
            \begin{frame}{Sources}
            \beamertemplatearticlebibitems
            \begin{thebibliography}{9}\bibitem{a}Almanac\end{thebibliography}
            \beamertemplatebookbibitems
            \begin{thebibliography}{9}\bibitem{b}Maps\end{thebibliography}
            \beamertemplatetextbibitems
            \begin{thebibliography}{9}\bibitem{c}Tables\end{thebibliography}
            \beamertemplatearrowbibitems
            \begin{thebibliography}{9}\bibitem{d}Charts\end{thebibliography}
            \end{frame}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-beamer" })
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let page = try #require(pdf.page(at: 0))
        try #require(pdf.pageCount == 1)
        // pdfLaTeX measures the hanging indent from the widest marker in each bibliography.
        for (word, left) in [("Almanac", 47.749), ("Maps", 47.749), ("Tables", 45.561), ("Charts", 40.000)] {
            let selection = try #require(pdf.findString(word, withOptions: []).first)
            #expect(abs(selection.bounds(for: page).minX - left) < 1, "\(word) の本文の左端")
        }
        #expect(pdf.findString("[1]", withOptions: []).count == 1)
        #expect(pdf.findString("▶", withOptions: []).count == 1)
        let bytes = String(decoding: try #require(page.dataRepresentation), as: UTF8.self)
        #expect(bytes.contains("SurimonoMathSymbols"))
    }
}
