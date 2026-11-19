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

    @Test("章のあるクラスだけが目次・図目次・表目次の前でページを改める")
    func contentsOpenings() {
        for (name, count) in [("article", 0), ("report", 3), ("book", 3), ("ltjsreport", 3)] {
            let tex =
                "\\documentclass{\(name)}"
                + #"\begin{document}Intro\tableofcontents\listoffigures\listoftables\end{document}"#
            let body = LaTeXConverter.convert(tex).body
            #expect(body.components(separatedBy: "data-latex-chapter-opening").count - 1 == count)
        }
    }

    @Test("飛ばした階層もある目次は入れ子の深さにかかわらず項目本来の字下げを選ぶ")
    func contentsLevels() {
        let body = LaTeXConverter.convert(
            #"\setcounter{tocdepth}{5}\tableofcontents\section{Start}\paragraph{Surface}\subparagraph{Detail}"#
        ).body
        #expect(body.contains(#"class="latex-toc-section""#))
        #expect(body.contains(#"class="latex-toc-paragraph""#))
        #expect(body.contains(#"class="latex-toc-subparagraph""#))
    }

    @Test("フレーム内の図表だけを本文に固定してフレームの外の指定を保つ")
    func beamerFrames() {
        let body = LaTeXConverter.convert(
            #"""
            \documentclass{beamer}\begin{document}\begin{frame}{Slides}
            \begin{center}\begin{figure}[t]F\end{figure}\end{center}
            \begin{table}[p]T\end{table}\end{frame}\begin{figure}[t]After\end{figure}\end{document}
            """#
        ).body
        #expect(body.components(separatedBy: #"data-latex-placement="H""#).count == 3)
        #expect(body.components(separatedBy: #"data-latex-placement="t""#).count == 2)
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

    @Test("学会誌の表題は表の前後で原稿に書かれた順序を保つ", arguments: ["[conference]{IEEEtran}", "[sigconf]{acmart}"])
    func tableCaptionOrder(declaration: String) throws {
        let body = LaTeXConverter.convert(
            #"\documentclass\#(declaration)\begin{document}"#
                + #"\begin{table}\caption{Upper title}\label{upper}\begin{tabular}{l}Upper cell\end{tabular}\end{table}"#
                + #"\begin{table}\begin{tabular}{l}Lower cell\end{tabular}\caption{Lower title}\end{table}\end{document}"#
        ).body
        let offsets = try ["Upper title", "Upper cell", "Lower cell", "Lower title"].map { text in
            try #require(body.range(of: text)).lowerBound
        }
        #expect(offsets == offsets.sorted())
    }

    @Test("memoir の図は罫線だけの行を罫線の高さで測り文字を含む行では行送りを残す")
    func memoirRuleBox() {
        let body = LaTeXConverter.convert(
            #"\documentclass{memoir}\begin{document}\begin{figure}\centering\rule{28mm}{2mm}\par A\rule{2mm}{2mm}\par\rule{2mm}{2mm}B\par\rule[1pt]{2mm}{2mm}\caption{Sample}\end{figure}\end{document}"#
        ).body
        #expect(body.components(separatedBy: "data-latex-rule-line").count == 2)
        #expect(
            body.contains(#"data-latex-rule-line style="text-align: center; text-indent: 0"><span class="latex-rule""#))
    }
}
