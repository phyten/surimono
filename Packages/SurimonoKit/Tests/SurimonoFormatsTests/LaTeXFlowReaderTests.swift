import SurimonoFormats
import Testing

struct LaTeXFlowReaderTests {
    @Test(
        "クラスとオプションから最初の段数が決まり、明示した一段を優先する",
        arguments: [
            ("[conference]{IEEEtran}", 2), ("[journal]{IEEEtran}", 2), ("[onecolumn]{IEEEtran}", 1),
            ("[sigconf]{acmart}", 2), ("[manuscript]{acmart}", 1), ("[preprint]{revtex4-2}", 1),
            ("[reprint]{revtex4-2}", 2), ("[twocolumn]{article}", 2), ("{article}\\usepackage{icml2025}", 2),
        ])
    func defaults(options: String, columns: Int) {
        let tex = "\\documentclass\(options)\\begin{document}Body\\end{document}"
        let fragment = LaTeXConverter.convert(tex)
        #expect(fragment.latexClass?.columns == columns)
        #expect(fragment.body.contains("data-latex-columns=\"2\"") == (columns == 2))
    }

    @Test("本文の段数、段抜き、均等割りと段間の寸法を読み順で渡す")
    func segments() {
        let body = LaTeXConverter.convert(
            #"""
            \documentclass{article}\setlength{\columnsep}{18pt}\columnseprule=.4pt
            \begin{document}\twocolumn[Title]Body\onecolumn
            \begin{multicols*}{2}Left\columnbreak Right\end{multicols*}
            \begin{strip}Across\end{strip}\end{document}
            """#
        ).body
        #expect(body.contains(#"data-latex-columns="2" data-latex-gap="18""#))
        #expect(body.contains(#"data-latex-rule="0.4"#))
        #expect(body.contains("<div data-latex-wide><p>Title</p>"))
        #expect(body.contains(#"data-latex-columns="1""#))
        #expect(body.contains(#"data-latex-balance="false""#))
        #expect(body.contains(#"data-latex-footnotes="page""#))
        #expect(body.contains(#"data-latex-break="column""#))
        #expect(body.contains("<div data-latex-wide><p>Across</p>"))
    }

    @Test("図表の種類・段抜き・配置文字と章・排出の区切りを保持する")
    func floats() {
        let body = LaTeXConverter.convert(
            #"""
            \chapter{Open}\begin{figure*}[!tp]Wide\end{figure*}\clearpage
            \begin{table}[H]Box\end{table}\newpage Next\pagebreak Last
            """#
        ).body
        #expect(body.contains(#"data-latex-float="figure" data-latex-placement="!tp" data-latex-wide"#))
        #expect(body.contains(#"data-latex-float="table" data-latex-placement="H""#))
        #expect(body.contains(#"data-latex-break="clear""#))
        #expect(body.contains(#"data-latex-break="page""#))
        #expect(body.components(separatedBy: #"data-latex-break="column""#).count == 3)
    }

    @Test("謝辞・遅れて届く脚注本文・同番号の再利用は異なる参照先を持つ")
    func notes() {
        let body = LaTeXConverter.convert(
            #"""
            \documentclass{article}\title{Title}\author{A\thanks{Symbol}}
            \begin{document}\maketitle A\footnotemark\footnotetext{Later}
            B\footnote[1]{Repeated}\end{document}
            """#
        ).body
        for id in ["fn-symbol-1", "fn-1", "fn-repeat-3"] {
            #expect(body.contains("href=\"#\(id)\""))
            #expect(body.contains("<li id=\"\(id)\""))
        }
    }
}
