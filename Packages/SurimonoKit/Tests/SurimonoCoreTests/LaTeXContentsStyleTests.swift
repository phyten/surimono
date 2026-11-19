import SurimonoFormats
import Testing

@testable import SurimonoCore

struct LaTeXContentsStyleTests {
    @Test("目次の章または記事の節は点線なしで一字あけ、図表と下位の項目は本文書体の点線を使う")
    func leadersAndFaces() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let body = HTMLDocumentBuilder.build(
            fragment: LaTeXConverter.convert(
                #"\documentclass{ltjsarticle}\begin{document}\tableofcontents\section{地図}\subsection{左岸}\end{document}"#
            ),
            format: .latex, theme: theme)
        #expect(body.contains(" data-latex-js-toc"))
        #expect(body.contains("nav.toc li > a { font-weight: normal; }"))
        #expect(body.contains("0.778em 100% repeat-x"))
        #expect(
            body.contains(
                #"body[data-latex-chapters="false"] nav.toc .latex-toc-section > a > .latex-page-leader { background: none; }"#
            ))
        #expect(body.contains("font-family: var(--tex-sans-fonts); font-weight: 500; --latex-toc-number-width: 3.7em;"))
    }
}
