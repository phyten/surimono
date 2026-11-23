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
        let scaled = folder == "022-batch-grid"
        let paginator = WebPaginator()
        var dimensions = "?"
        if scaled {
            paginator.inspectPrintLayout = { view in
                do {
                    let value = try await view.evaluateForPrinting(
                        """
                        const box = document.querySelector('.latex-graphic-box');
                        if (!box) return null;
                        const ink = box.firstElementChild, table = ink.querySelector('table');
                        if (!table) return 'table missing';
                        const size = getComputedStyle(ink), shape = el => {
                            const r = el.getBoundingClientRect();
                            return [r.top, r.width, r.height].map(n => +n.toFixed(2));
                        };
                        return JSON.stringify({natural:[size.width,size.height], matrix:size.transform,
                          rows:[...table.rows].slice(0,3).map(shape), struts:table.querySelectorAll('.latex-array-strut').length,
                          font:getComputedStyle(table).fontFamily, dpr:devicePixelRatio});
                        """, until: .now + .seconds(3))
                    if let value = value as? String { dimensions = value }
                } catch { dimensions = String(describing: error) }
            }
        }
        let renderer = DocumentRenderer(paginateWithResult: { request in try await paginator.paginate(request) })
        let result = try await renderer.prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let referenceURL = corpus.appendingPathComponent("Snapshots/reference/latex/\(folder.prefix(3)).pdf")
        let reference = try #require(PDFDocument(url: referenceURL))
        // Four sampled edges enter each comparison. A 0.025pt pixel keeps their combined
        // quantization below the 0.3pt strut tolerance. PDFKit selection centres depend on font metrics.
        func inkDistance(_ top: String, _ bottom: String, in document: PDFDocument) throws -> CGFloat {
            let first = try #require(document.page(at: 0))
            let upper = try printedInk(of: top, in: document, on: first, scale: 40)
            let lower = try printedInk(of: bottom, in: document, on: first, scale: 40)
            return upper.minY - lower.minY
        }
        let row = scaled ? "Slate" : "Firm"
        let caption = scaled ? "Three" : "Schedule"
        let distance = try inkDistance(row, caption, in: pdf)
        let expected = try inkDistance(row, caption, in: reference)
        #expect(abs(distance - expected) <= 0.3, "実測 \(distance) pt、参照 \(expected) pt")
        guard scaled else { return }
        let heading = try inkDistance("Batch comparison grid", "Amber", in: pdf)
        let texHeading = try inkDistance("Batch comparison grid", "Amber", in: reference)
        func anchors(_ deck: PDFDocument) -> String {
            guard let sheet = deck.page(at: 0) else { return "page missing" }
            let positions = ["Batch comparison grid", "Maximum deviation", "Amber", "Slate", "Three"].map { text in
                guard let ink = try? printedInk(of: text, in: deck, on: sheet, scale: 40) else { return "\(text)=?" }
                return String(
                    format: "%.2f/%.2f/w%.2f", ink.minX, sheet.bounds(for: .mediaBox).maxY - ink.minY, ink.width)
            }.joined(separator: ",")
            return "\(positions) fonts=\(baseFonts(in: sheet.dataRepresentation ?? Data()))"
        }
        #expect(
            abs(heading - texHeading) < 1,
            "表題→Amber \(heading)pt、実 TeX \(texHeading)pt。表題/表見出し/Amber/Slate/Three の x/y/幅=\(anchors(pdf)) TeX=\(anchors(reference)) DOM=\(dimensions)"
        )
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
