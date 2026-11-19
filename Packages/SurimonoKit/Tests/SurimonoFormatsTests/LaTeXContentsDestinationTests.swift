import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXContentsDestinationTests {
    @Test("和文の章・同名の節・図表には表示名に依存しない一意の目次の行き先がある")
    func destinations() {
        let repeated = String(repeating: #"\section{同じ題}"#, count: 64)
        let body = LaTeXConverter.convert(
            #"\documentclass{ltjsreport}\usepackage{hyperref}\begin{document}\pagenumbering{roman}\tableofcontents\listoffigures\listoftables\chapter*{はじめに}\phantomsection\addcontentsline{toc}{chapter}{序文}\clearpage\pagenumbering{arabic}\chapter{本文}"#
                + #"\renewcommand{\thesection}{節\arabic{section}}"# + repeated
                + #"\begin{figure}\caption{同じ題}\end{figure}\begin{table}\caption{同じ題}\end{table}\end{document}"#
        ).body
        let contents = body.components(separatedBy: "</nav>").dropLast().joined()
        let targets = contents.matches(of: /href="#([^"]+)"/).map { String($0.1) }
        #expect(targets.count == 68)
        #expect(Set(targets).count == targets.count)
        #expect(targets.allSatisfy { id in id.utf8.allSatisfy { $0 < 128 } && body.contains("id=\"\(id)\"") })
        #expect(contents.contains("<a href=\"#sec-u1\">序文</a>"))
        #expect(body.contains("<h2 id=\"sec-u1\">はじめに</h2>"))
        #expect(body.contains(#"data-latex-page-action="pagenumbering" data-value="roman""#))
        #expect(body.contains(#"data-latex-page-action="pagenumbering" data-value="arabic""#))
    }
}
