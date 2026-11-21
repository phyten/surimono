import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXTablePrintingTests {
    @Test(
        "配列の最終行と下の表題との間隔を実 TeX に合わせ、拡大表の先頭位置も保つ", .timeLimit(.minutes(1)),
        arguments: ["012-plates", "022-batch-grid"])
    func tableStrut(_ folder: String) async throws {
        let corpus = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let file = corpus.appendingPathComponent("Snapshots/corpus/latex/\(folder)/main.tex")
        let source = DocumentSource(data: try Data(contentsOf: file), fileURL: file, format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let result = try await DocumentRenderer().prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let page = try #require(pdf.page(at: 0))
        let scaled = folder == "022-batch-grid"
        let referenceURL = corpus.appendingPathComponent("Snapshots/reference/latex/\(folder.prefix(3)).pdf")
        let reference = try #require(PDFDocument(url: referenceURL))
        // Compare the same outlines in each PDF: rounded letters extend slightly below the baseline.
        func rowToCaption(_ document: PDFDocument) throws -> CGFloat {
            let first = try #require(document.page(at: 0))
            let row = try printedInk(of: scaled ? "Slate" : "Firm", in: document, on: first)
            let caption = try printedInk(of: scaled ? "Three" : "Schedule", in: document, on: first)
            return row.minY - caption.minY
        }
        let distance = try rowToCaption(pdf)
        let expected = try rowToCaption(reference)
        #expect(abs(distance - expected) <= 0.3, "実測 \(distance) pt、参照 \(expected) pt")
        guard scaled else { return }
        let heading = try #require(pdf.findString("Batch comparison grid").first).bounds(for: page)
        let row = try #require(pdf.findString("Amber").first).bounds(for: page)
        // The real TeX heading-to-row baseline distance is 51pt; the selection centres differ by under 1pt.
        #expect(abs(heading.midY - row.midY - 51) < 1)
    }

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
