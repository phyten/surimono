import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXConferencePrintingTests {
    @Test(
        "学会原稿の査読番号は余白に独立して刷り、完成版でも本文を単語で検索できる", .timeLimit(.minutes(1)),
        arguments: [
            #"\usepackage{neurips_2026}"#, #"\usepackage[main,final]{neurips_2026}"#,
            #"\usepackage{iclr2027_conference,times}"#, #"\usepackage{iclr2027_conference,times}\iclrfinalcopy"#,
        ])
    func reviewFurniture(_ preamble: String) async throws {
        let tex =
            #"\documentclass{article}"# + preamble + #"""
                \title{Spacing study}\author{Rail desk}
                \begin{document}\maketitle
                \begin{abstract}Calibrated spacers.\end{abstract}
                \section*{Results}Repeatable measurement.
                \newpage Second sheet.\end{document}
                """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        settings.options.latexFurniture = .style
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings)
        let pdf = result.logicalDocument
        #expect(pdf.pageCount == 2)
        let page = try #require(pdf.page(at: 0))
        let second = try #require(pdf.page(at: 1))
        func bounds(_ word: String, on page: PDFPage) throws -> CGRect {
            try #require(pdf.findString(word, withOptions: .caseInsensitive).first { $0.pages.contains(page) }).bounds(
                for: page)
        }
        let abstract = try bounds("Calibrated", on: page)
        let body = try bounds("Repeatable", on: page)
        #expect(body.minX >= 107 && body.minX < 110)
        #expect(abstract.minX > body.minX)
        let iclr = preamble.contains("iclr")
        let final = preamble.contains("final")
        let margin = CGRect(x: 65, y: 55, width: 37, height: 700)
        let numbers = page.selection(for: margin)?.string ?? ""
        if final {
            #expect(numbers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if iclr {
            let zero = try bounds("000", on: page)
            let one = try bounds("001", on: page)
            #expect(abs(zero.minX - 73.13) < 1)
            #expect(abs(zero.midY - one.midY - 11.955) < 0.5)
            #expect(abs(try bounds("054", on: second).midY - zero.midY) < 0.5)
        } else {
            let first = try bounds("1", on: page)
            #expect(abs(first.maxX - 98.04) < 1)
            #expect(abs(first.minY - abstract.minY) < 3)
            let title = try bounds("Spacing", on: page)
            #expect(
                page.selection(for: CGRect(x: 65, y: title.minY, width: 37, height: title.height))?.string?.isEmpty
                    != false)
            #expect((second.selection(for: margin)?.string ?? "").contains("4"))
        }
        if iclr {
            let header =
                final
                ? "Published as a conference paper at ICLR 2027" : "Under review as a conference paper at ICLR 2027"
            let reading = try ReadingPDFExporter.document(
                from: result.viewDocument, entries: [], title: "Spacing study", furniture: result.viewFurniture)
            for index in 0..<2 {
                let printed = try #require(reading.page(at: index))
                #expect(printed.string?.contains(header) == true)
                // This end of the rule has no header glyphs. Its 0.4pt stroke covers part of a pixel.
                let ink = try (752...753).map { try RenderingFixtures.pixel(printed, x: 490, y: $0)[0] }
                #expect(ink.min() ?? 255 < 230)
                #expect(try RenderingFixtures.pixel(printed, x: 505, y: 752)[0] > 245)
                let lines = try #require(result.viewFurniture[index]?.lines)
                #expect(lines.top == [header, "", ""])
                #expect(abs(lines.headRule - 0.3985) < 0.001)
                #expect(lines.bottom == ["", String(index + 1), ""])
            }
        } else {
            #expect(result.viewFurniture[0]?.lines.isEmpty ?? true)
            #expect(result.viewFurniture[1]?.lines.bottom == ["", "2", ""])
            #expect((page.string ?? "").contains("NeurIPS 2026"))
        }
    }
}
