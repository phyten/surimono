import SurimonoFormats
import Testing

struct LaTeXBeamerTests {
    private func document(_ source: String, preamble: String = "") -> String {
        LaTeXConverter.convert("\\documentclass{beamer}" + preamble + "\\begin{document}" + source + "\\end{document}")
            .body
    }

    @Test("子リストの字級で直前の段落が閉じる場合を、明示した段落末と区別する")
    func nestedListParagraph() {
        for ending in ["", "\\par", "\n\n"] {
            let html = document(
                "\\begin{frame}\\begin{itemize}\\item Outer\(ending)\\begin{itemize}\\item Inner"
                    + "\\end{itemize}\\end{itemize}\\end{frame}")
            #expect(html.contains(" data-beamer-closes-paragraph") == ending.isEmpty)
        }
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

    @Test("フレームの見出しを本文と分け、ブロックの題を本文と別の行にする")
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
        #expect(html.contains(#"<h2 class="beamer-frame-title">Fixed rail</h2>"#))
        #expect(html.contains(#"<p class="beamer-frame-subtitle">First reading</p>"#))
        #expect(html.contains(#"class="beamer-block-title">Observation</div>"#))
        #expect(html.contains("<p>The folded card held.</p>"))
        #expect(html.contains(#"<h2 class="beamer-frame-title">Readings</h2>"#))
        #expect(!html.contains("Trial") && !html.contains("References") && !html.contains("Short"))
        #expect(html.contains("Model Rail Desk") && html.contains("<em>Register</em>"))
    }

    @Test("投影用の節見出しは本文に出さず明示した目次にだけ残す")
    func contents() {
        let html = document(#"\begin{frame}\tableofcontents\end{frame}\section{Trial}\frame{Results}"#)
        #expect(html.components(separatedBy: "Trial").count == 2)
        #expect(html.contains(#"class="beamer-toc-section""#))
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
        #expect(html.contains(#"class="latex-caption-label">Figure:</span> Folded edge"#))
        #expect(html.contains(#"class="latex-caption-label">Table:</span> Spacer heights"#))
        #expect(html.contains(#"class="latex-caption-label">Figure 2:</span> Lower edge"#))
        #expect(html.contains(#"class="latex-caption-label">Figure:</span> Final edge"#))
        #expect(html.contains(##"href="#fig-1">1</a>"##))
        #expect(html.components(separatedBy: #"data-latex-placement="H""#).count == 5)
    }
}

extension LaTeXBeamerTests {
    @Test("用紙はクラス指定のミリ寸法、本文はサイズファイルの実ポイント数を使う")
    func slideGeometry() throws {
        for (options, width, height, font) in [
            ("", 128.0, 96.0, 10.95), ("aspectratio=169,bigger", 160, 90, 12),
            ("aspectratio=1610,smaller", 160, 100, 10), ("aspectratio=149,8pt", 140, 90, 8),
            ("aspectratio=54,14pt", 125, 100, 14.4), ("aspectratio=43,17pt", 128, 96, 17.28),
            ("aspectratio=32,20pt", 135, 90, 20.74), ("aspectratio=141,9pt", 148.5, 105, 9),
            ("aspectratio=2013,11pt", 140, 91, 10.95), ("10pt", 128, 96, 10), ("12pt", 128, 96, 12),
        ] {
            let info = LaTeXConverter.documentClassInfo("\\documentclass[\(options)]{beamer}")
            let size = try #require(info.beamerPageSize)
            #expect(abs(size.width - width * 72 / 25.4) < 0.001)
            #expect(abs(size.height - height * 72 / 25.4) < 0.001)
            #expect(info.beamerFontSize == font)
            #expect(abs(info.pageBox.left - 10 * 72 / 25.4) < 0.001)
        }
    }

    @Test("セリフ体のテーマは数式・本文を指定通りに切り替え、他のテーマ名を正直に残す")
    func fontThemes() throws {
        func deck(_ setup: String) -> HTMLFragment {
            LaTeXConverter.convert(
                "\\documentclass{beamer}" + setup + #"\begin{document}\frame{$u_2 + \frac{3}{v}$}\end{document}"#)
        }
        let normal = deck(#"\usetheme{Madrid}"#)
        #expect(normal.latexClass?.unsupportedBeamerTheme == "Madrid")
        let svg = try #require(normal.body.components(separatedBy: "</svg>").first)
        #expect(svg.contains("KaTeX_SansSerif"))
        for (setup, serifText) in [
            (#"\usefonttheme[onlymath]{serif}"#, false), (#"\usefonttheme{serif}"#, true),
            (#"\usefonttheme{professionalfonts}"#, false),
        ] {
            let output = deck(setup)
            #expect(output.latexClass?.beamerUsesSerifText == serifText)
            #expect(output.latexClass?.unsupportedBeamerTheme == nil)
            #expect(!output.body.contains("KaTeX_SansSerif"))
        }
    }

    @Test("節の目次は後続のフレームを指し、付録と本文の項目を混ぜない")
    func sectionNavigation() throws {
        let source = #"""
            \documentclass{beamer}
            \AtBeginSection[]{\frame{\tableofcontents[currentsection,hideallsubsections]}}
            \begin{document}\section{One}\subsection{Near}\frame{Start}
            \section{Two}\frame{Middle}\appendix\section{End}\frame{\sectionpage}
            \end{document}
            """#
        let fragment = LaTeXConverter.convert(source)
        let sections = try #require(fragment.latexClass?.beamerSections)
        #expect(sections.map(\.title) == ["One", "Near", "Two", "End"])
        #expect(sections.map(\.firstFrame) == [1, 2, 3, 5])
        #expect(fragment.body.contains("Section 3"))
        #expect(fragment.body.contains("data-shaded"))
        #expect(!fragment.body.contains("Near"))
    }

    @Test("脚注を置いた段階ではそのページの末尾にだけ注があり、次の段階では番号を進め直さない")
    func overlayNotes() {
        let html = document(#"\frame{\only<1>{Sun}\only<2>{Rain} North\footnote{Wind}}\frame{South\footnote{Shade}}"#)
        #expect(html.components(separatedBy: #"class="beamer-footnotes""#).count - 1 == 3)
        #expect(html.components(separatedBy: #"value="1""#).count - 1 == 2)
        #expect(html.contains(#"value="2""#))
    }

    @Test("配布時に除外したフレームと発表者ノートを刷らず、読み取れない段階を一枚と数える")
    func handoutAndUnknown() {
        let body =
            #"\begin{document}\mode<handout>{\frame{Paper}}\begin{frame}<handout:0>Screen\end{frame}\frame{\only<nonsense>{Dock}\note{Private}}\end{document}"#
        let fragment = LaTeXConverter.convert(#"\documentclass[handout]{beamer}"# + body)
        #expect(fragment.body.contains("Paper") && fragment.body.contains("Dock"))
        #expect(!fragment.body.contains("Private") && !fragment.body.contains("Screen"))
        #expect(fragment.latexClass?.unreadableBeamerFrames == 1)
    }
    @Test("三段の項目と列挙を既定の三角と通し番号で区別し、定理の参照には共有カウンターを使う")
    func nestedListsAndTheorems() {
        let html = document(
            #"""
            \frame{\begin{itemize}\item Tide\begin{itemize}\item River\begin{itemize}\item Brook\end{itemize}\end{itemize}\end{itemize}
            \begin{enumerate}\item East\begin{enumerate}\item West\begin{enumerate}\item North\end{enumerate}\end{enumerate}\end{enumerate}}
            \frame{\begin{lemma}Blue.\end{lemma}\begin{fact}[Harbour]\label{harbour}Green.\end{fact}
            \begin{claimdesk}Deep.\end{claimdesk}See \ref{harbour}.}
            """#, preamble: #"\newtheorem{claimdesk}{Coral claim}"#)
        #expect(html.components(separatedBy: ">▶</span>").count - 1 == 3)
        for label in ["1.", "1.1", "1.1.1"] { #expect(html.contains(">\(label)</span>")) }
        for title in ["Lemma", "Fact (Harbour)", "Coral claim"] {
            #expect(html.contains("class=\"beamer-block-title\">\(title)</div>"))
        }
        #expect(html.contains(##"href="#thm-2">2</a>"##))
    }

    @Test("隠した項目では実TeXと同じく脚注本文を残し、onlyで除いた内容からは脚注を採らない")
    func coveredNotes() throws {
        let html = document(
            #"\frame{\only<1>{First}\only<2>{Second\footnote{Foam}}\uncover<2>{Oyster\footnote{Shell}}\begin{itemize}\item<2>Gull\footnote{Wing}\end{itemize}}"#
        )
        let pages = html.components(separatedBy: #"<section class="beamer-frame""#)
        try #require(pages.count == 3)
        #expect(!pages[1].contains("Foam") && pages[2].contains("Foam"))
        for page in pages.dropFirst() {
            #expect(page.contains("Shell") && page.contains("Wing"))
        }
    }

    @Test("文献の各部分を本文に現れた順のブロックにし、著者だけの項目も残す")
    func bibliographyBlocks() {
        let html = document(
            #"\frame{\begin{thebibliography}{1}\bibitem{tide}Reed.\newblock Tide.\newblock Bay.\newblock Handout.\bibitem{gull}Gull.\end{thebibliography}}"#
        )
        #expect(html.contains("Reed.") && html.contains("Gull."))
        for (role, text) in [("title", "Tide."), ("location", "Bay."), ("note", "Handout.")] {
            #expect(html.contains("class=\"beamer-bib-\(role)\">\(text)</div>"))
        }
    }

    @Test("逐語環境に記したフレーム終端や段階指定をデッキの構造として読まない")
    func fragileFrameTerminator() {
        let html = document(
            #"""
            \begin{frame}[fragile]{Escapes}
            \begin{verbatim}
            example: \end{frame}
            \only<2>{quoted}
            \end{verbatim}
            Printed tail.
            \end{frame}
            """#)
        #expect(html.components(separatedBy: #"<section class="beamer-frame""#).count - 1 == 1)
        #expect(html.contains(#"\end{frame}"#) && html.contains("quoted") && html.contains("Printed tail."))
    }

}
