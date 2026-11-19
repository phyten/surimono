import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXTablePrintingTests {
    @Test("伸縮表では太字の語を一行に収め、固定幅列と同行の基準線を実寸で刷る", .timeLimit(.minutes(1)))
    func flexibleTable() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass{article}\usepackage{array,tabularx,booktabs}
                \newcolumntype{L}{>{\bfseries}l}
                \begin{document}
                \begin{tabularx}{\linewidth}{@{}Lm{16mm}b{16mm}X@{}}\toprule
                Mark&Before&After&Observation\\\midrule
                Rim&rough&smooth&The second pass removed the ridge at the joint.\\
                Pin&level&level&Rotation left the reference line in place.\\\bottomrule
                \end{tabularx}\end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let result = try await DocumentRenderer().prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let page = try #require(pdf.page(at: 0))
        func bounds(_ text: String) throws -> CGRect {
            let selection = try #require(pdf.findString(text).first)
            #expect(selection.selectionsByLine().count == 1)
            return selection.bounds(for: page)
        }
        let mark = try bounds("Mark")
        for (word, offset) in [("Before", 39.16), ("After", 96.47), ("Observation", 153.78)] {
            let cell = try bounds(word)
            #expect(abs(cell.minX - mark.minX - offset) < 1.5)
            #expect(abs(cell.maxY - mark.maxY) < 1.5)
        }
        let rim = try bounds("Rim")
        for word in ["rough", "smooth", "The second"] {
            let cell = try bounds(word)
            #expect(abs(cell.maxY - rim.maxY) < 1.5)
        }
    }
}
