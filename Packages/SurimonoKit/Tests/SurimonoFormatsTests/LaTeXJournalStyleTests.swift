import Testing

@testable import SurimonoFormats

struct LaTeXJournalStyleTests {
    private func paper(_ declaration: String, _ source: String, preamble: String = "") -> HTMLFragment {
        LaTeXConverter.convert(#"\documentclass\#(declaration)\#(preamble)\begin{document}\#(source)\end{document}"#)
    }

    @Test("IEEE は要旨と索引用語を追い込みにし、節と図表を学会の番号で引用する")
    func ieee() {
        let html = paper(
            "[conference]{IEEEtran}",
            #"""
            \title{Fixture}\maketitle\begin{abstract}First sentence.\end{abstract}
            \begin{IEEEkeywords}Cards\end{IEEEkeywords}
            \section{Bench trial}\subsection{Slot}\label{s}
            \begin{figure}\caption{Drawing}\end{figure}
            \begin{table}\caption{Measurements}\label{t}\end{table}
            \ref{s} and \ref{t}.
            """#
        ).body
        #expect(html.contains(#"<strong class="latex-abstract-label">Abstract—</strong>First sentence."#))
        #expect(html.contains("<strong>Index Terms—</strong>Cards"))
        #expect(html.contains(#"<span class="secnum">I.</span>Bench trial"#))
        #expect(html.contains(#"<span class="secnum">A.</span>Slot"#))
        #expect(html.contains("Fig. 1</span>. Drawing"))
        #expect(html.contains("TABLE I</span><br>Measurements"))
        #expect(html.contains(##"href="#sec-I-A">I-A</a>"##))
        #expect(html.contains(##"href="#tab-I">I</a>"##))
    }

    @Test("APS プレプリントは日付と概要見出しを刷り、参考文献は罫線で区切る")
    func preprint() {
        let source = #"""
            \title{Fixture}\date{14 May 2026}\begin{abstract}Trial.\end{abstract}\maketitle
            \section{Bench trial}\subsection{Loads}
            \begin{figure}\caption{Side view}\end{figure}\begin{table}\caption{Spacer heights}\end{table}
            \begin{thebibliography}{1}\bibitem{a}Primary work.\end{thebibliography}
            """#
        let result = paper("[aps,preprint]{revtex4-2}", source)
        #expect(result.latexClass?.pointSize == 12)
        #expect(result.body.contains("(Dated: 14 May 2026)</p>"))
        #expect(result.body.contains(#"<p class="abstract-title">Abstract</p>"#))
        #expect(result.body.contains(#"class="secnum">I.</span>Bench trial"#))
        #expect(result.body.contains(#"class="secnum">A.</span>Loads"#))
        #expect(result.body.contains("FIG. 1</span>. Side view"))
        #expect(result.body.contains("TABLE I</span>. Spacer heights"))
        #expect(result.body.contains(#"<hr class="latex-bibliography-rule""#))
        #expect(result.body.contains("Primary work."))
        #expect(!result.body.contains(">References</h2>"))

        let reprint = paper("[aps,reprint]{revtex4-2}", source)
        #expect(reprint.body.contains("<div data-latex-wide>\n<div class=\"abstract"))
        #expect(!reprint.body.contains("abstract-title"))
    }

    @Test("罫線だけの図は自然な高さを使い、図内の本文の行送りは保つ", arguments: ["[preprint]{revtex4-2}", "{elsarticle}"])
    func ruleFigure(declaration: String) {
        let html = paper(
            declaration,
            #"""
            \begin{figure}[ht]\centering\rule{28mm}{2mm}\caption{Side view}\end{figure}
            \begin{figure}[ht]\centering\rule{28mm}{2mm} Text\caption{Side view}\end{figure}
            """#
        ).body
        #expect(html.components(separatedBy: "data-latex-rule-line").count == 2)
        #expect(html.contains("Text</p>"))
    }

    @Test("LNCS の要旨と図表の見出し・参考文献番号に終止点を付ける")
    func proceedings() {
        let html = paper(
            "{llncs}",
            #"""
            \begin{abstract}Paper.\keywords{One\and Two}\end{abstract}
            \section{Bench}\begin{figure}\caption{Side view}\end{figure}\begin{table}\caption{Gauge}\end{table}
            \begin{thebibliography}{1}\bibitem{a}Reference.\end{thebibliography}
            """#
        ).body
        #expect(html.contains(#"<strong class="latex-abstract-label">Abstract. </strong>Paper."#))
        #expect(html.contains("One · Two"))
        #expect(html.contains(#"class="secnum">1</span>Bench"#))
        #expect(html.contains("Fig. 1</span>. Side view"))
        #expect(html.contains("Table 1</span>. Gauge"))
        #expect(html.contains(#"class="bib-label">1.</span>"#))
    }

    @Test("Elsevier の節番号と図名をクラスに合わせ、原稿の表名・番号の再定義を保つ")
    func customCaptions() {
        let html = paper(
            "[preprint]{elsarticle}",
            #"""
            \section{Bench}\begin{figure}\caption{Side view}\end{figure}
            \begin{table}\caption{Gauge}\end{table}
            """#, preamble: #"\renewcommand{\tablename}{Specimen}\renewcommand{\thetable}{\Alph{table}}"#
        ).body
        #expect(html.contains(#"class="secnum">1.</span>Bench"#))
        #expect(html.contains("Figure 1</span>: Side view"))
        #expect(html.contains("Specimen A</span>: Gauge"))
    }
}
