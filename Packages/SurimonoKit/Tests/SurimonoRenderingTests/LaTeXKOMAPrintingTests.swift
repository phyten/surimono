import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXKOMAPrintingTests {
    @Test("KOMA 論文は題名・副題・要旨を参照 PDF の高さに置き、参考文献を節と同じ書体で刷る", .timeLimit(.minutes(1)))
    func articleFrontMatter() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[abstract=true]{scrartcl}
                \begin{document}
                \title{Spacer trial}\subtitle{A bench memorandum}\author{Model Rail Desk}
                \publishers{Paper Model Workshop}\date{}\maketitle
                \begin{abstract}A folded spacer fixes the height of a model rail.
                Two card thicknesses were tested in the same slot.\end{abstract}
                \section{Bench trial}
                The thin card entered freely. The folded card held the rail level at the second mark.
                \begin{figure}[ht]\centering\rule{28mm}{2mm}\caption{Side view of the spacer}\end{figure}
                \begin{thebibliography}{1}\bibitem{a}Stock\end{thebibliography}
                \end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.options.latexMargins = .style
        let rendered = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = rendered.logicalDocument
        #expect(pdf.pageCount == 1)
        let page = try #require(pdf.page(at: 0))
        func match(_ text: String) throws -> PDFSelection {
            let selection = try #require(pdf.findString(text).first)
            try #require(selection.pages.first == page)
            return selection
        }
        func font(_ text: String) throws -> NSFont {
            let selection = try match(text)
            let string = try #require(selection.attributedString)
            return try #require(string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        }
        // CMU includes taller accents than the subset in the reference. Compare selection centres
        // measured by PDFKit on both PDFs, which avoids treating the whole font ascent as visible ink.
        for (text, expectedCenter): (String, CGFloat) in [
            ("Spacer trial", 136.71), ("A bench memorandum", 158.29), ("Model Rail Desk", 186.53),
            ("Paper Model Workshop", 215.37), ("Abstract", 262.20), ("Bench trial", 325.86),
        ] {
            let center = try page.bounds(for: .mediaBox).maxY - match(text).bounds(for: page).midY
            #expect(abs(center - expectedCenter) < 6)
        }
        let section = try font("Bench trial")
        // PDFKit substitutes a system font in attributedString for embedded subset faces;
        // glyph advances in the PDF itself retain the original Computer Modern sans metrics.
        for (text, width): (String, CGFloat) in [
            ("Spacer trial", 108.5), ("A bench memorandum", 124.2), ("Abstract", 39.0), ("References", 70.7),
        ] {
            let bounds = try match(text).bounds(for: page)
            #expect(abs(bounds.width - width) < 3)
        }
        let references = try font("References")
        #expect(abs(section.pointSize - references.pointSize) < 0.2)
    }

    @Test("scrreprt の表紙の題は scrbook と同じく見出しの書体（サンセリフの太字）の \\huge で刷る", .timeLimit(.minutes(1)))
    func reportTitleFont() async throws {
        var widths: [String: CGFloat] = [:]
        for name in ["scrbook", "scrreprt"] {
            let tex =
                #"\documentclass{"# + name
                + #"}\title{Spacer trial}\author{Desk}\begin{document}\maketitle Body.\end{document}"#
            let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
            let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
            let pdf = try await DocumentRenderer().prepare(
                DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings
            ).logicalDocument
            let selection = try #require(pdf.findString("Spacer trial").first)
            let page = try #require(selection.pages.first)
            widths[name] = selection.bounds(for: page).width
        }
        let book = try #require(widths["scrbook"])
        let report = try #require(widths["scrreprt"])
        #expect(abs(book - report) < 1, "scrbook \(book) scrreprt \(report)")
    }
}
