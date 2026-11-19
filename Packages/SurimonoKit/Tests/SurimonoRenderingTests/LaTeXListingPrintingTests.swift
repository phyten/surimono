import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXListingPrintingTests {
    @Test(
        "和文のプログラムの予約語は既定のタイプライターと指定した実太字のどちらでも一度だけ検索・コピーできる",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func boldKeywords(selectsMenlo: Bool) async throws {
        let tex = #"""
            \documentclass{jsarticle}\usepackage{listings}
            \#(selectsMenlo ? #"\setmonofont{Menlo}"# : "")
            \begin{document}
            蔵書の例\footnote{説明。}
            \begin{lstlisting}[language=Python]
            def lend(books):
                return books
            \end{lstlisting}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let pdf = result.logicalDocument
        let text = try #require(pdf.string)
        let bytes = try #require(pdf.dataRepresentation())
        let fonts = String(decoding: bytes, as: UTF8.self)
        #expect(fonts.contains(selectsMenlo ? "+Menlo-Bold" : "+KaTeX_Typewriter-Regular"))
        for word in ["def", "return"] {
            #expect(pdf.findString(word).count == 1)
            #expect(text.components(separatedBy: word).count == 2)
        }
    }
}
