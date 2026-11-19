import SurimonoFormats
import Testing

struct LaTeXBeamerTests {
    private func document(_ source: String, preamble: String = "") -> String {
        LaTeXConverter.convert("\\documentclass{beamer}" + preamble + "\\begin{document}" + source + "\\end{document}")
            .body
    }

    @Test(
        "フレーム内の表題命令で題名・著者・所属・日付を読む順に一度ずつ刷る",
        arguments: [#"\frame[plain]{\titlepage}"#, #"\begin{frame}\maketitle\end{frame}"#])
    func titlePage(frame: String) throws {
        let html = document(
            frame,
            preamble:
                #"\title{Folded card}\author{Model Desk}\institute[Short]{Paper Workshop}\date{14 May 2026}"#)
        var remaining = html[...]
        for field in ["Folded card", "Model Desk", "Paper Workshop", "14 May 2026"] {
            #expect(html.components(separatedBy: field).count == 2)
            let range = try #require(remaining.range(of: field))
            remaining = remaining[range.upperBound...]
        }
        #expect(!html.contains("Short"))
    }

    @Test("フレームの見出しを本文と分け、ブロックの題を独立した太字の行にする")
    func headings() {
        let html = document(
            #"""
            \section{Trial}
            \begin{frame}<1->[plain]{Fixed rail}{First reading}
            \begin{block}{Observation}The folded card held.\end{block}
            \end{frame}
            \frame{\frametitle[Short]{Readings}\begin{thebibliography}{1}
            \bibitem{card}Model Rail Desk, \emph{Register}.\end{thebibliography}}
            """#)
        #expect(html.contains(#"<h2 class="latex-beamer-frame-title">Fixed rail</h2>"#))
        #expect(html.contains(#"<h3 class="latex-beamer-frame-title">First reading</h3>"#))
        #expect(html.contains(#"<strong>Observation</strong></p>"#))
        #expect(html.contains("<p>The folded card held.</p>"))
        #expect(html.contains(#"<h2 class="latex-beamer-frame-title">Readings</h2>"#))
        #expect(!html.contains("Trial") && !html.contains("References") && !html.contains("Short"))
        #expect(html.contains("Model Rail Desk") && html.contains("<em>Register</em>"))
    }

    @Test("投影用の節見出しは本文に出さず明示した目次にだけ残す")
    func contents() {
        let html = document(#"\begin{frame}\tableofcontents\end{frame}\section{Trial}\frame{Results}"#)
        #expect(html.components(separatedBy: "Trial").count == 2)
        #expect(html.contains(#"class="latex-toc-section""#))
    }

    @Test("図表のキャプションは名前だけを刷り番号を参照用に保ち、明示した番号付きを区別する")
    func captions() {
        let html = document(
            #"""
            \frame{\begin{figure}\caption{Folded edge}\label{edge}\end{figure}}
            \begin{frame}\begin{table}\caption{Spacer heights}\end{table}\end{frame}
            \frame{\setbeamertemplate{caption}[numbered]\begin{figure}\caption{Lower edge}\end{figure}}
            \frame{\begin{figure}\caption{Final edge}\end{figure}See \ref{edge}.}
            """#)
        #expect(html.contains(#"class="latex-caption-label">Figure</span>: Folded edge"#))
        #expect(html.contains(#"class="latex-caption-label">Table</span>: Spacer heights"#))
        #expect(html.contains(#"class="latex-caption-label">Figure 2</span>: Lower edge"#))
        #expect(html.contains(#"class="latex-caption-label">Figure</span>: Final edge"#))
        #expect(html.contains(##"href="#fig-1">1</a>"##))
        #expect(html.components(separatedBy: #"data-latex-placement="H""#).count == 5)
    }
}
