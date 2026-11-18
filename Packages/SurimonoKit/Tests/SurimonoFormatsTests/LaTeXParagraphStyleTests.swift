import SurimonoFormats
import Testing

struct LaTeXParagraphStyleTests {
    @Test("文中の数式と直後の句読点は一緒に改行し、空白で離れた記号や別行数式はまとめない")
    func mathPunctuation() {
        for formula in ["$x$", #"\(x\)"#, #"\ensuremath{x}"#, #"\begin{math}x\end{math}"#] {
            for marks in [".", ",", ";", ":", ")", ")."] {
                let html = LaTeXConverter.convert(formula + marks + " After").body
                #expect(html.contains(#"<span class="latex-nowrap"><span class="math math-inline">"#))
                #expect(html.contains("</svg></span>\(marks)</span> After"))
            }
            #expect(!LaTeXConverter.convert(formula + " .").body.contains("latex-nowrap"))
        }
        #expect(!LaTeXConverter.convert(#"\[x\]."#).body.contains("latex-nowrap"))
    }

    @Test("短い引用と複数段落の引用を区別し、小見出しと本文の間に余分な空白を挟まない")
    func quoteAndRunInHeading() {
        let html = LaTeXConverter.convert(
            #"\begin{quote}Short\end{quote}\begin{quotation}Long\end{quotation}\paragraph{Head} Text."#
        ).body
        #expect(html.contains("<blockquote>\n<p>Short</p>"))
        #expect(html.contains("<blockquote class=\"latex-quotation\">\n<p>Long</p>"))
        #expect(html.contains("Head</h5><p>Text.</p>"))
    }

    @Test("独自環境の冒頭の字下げを抑え、見出しと斜体の本文の語間を残す")
    func environmentSpacing() {
        let html = LaTeXConverter.convert(
            #"""
            \newenvironment{note}[1]{\par\medskip\noindent\textbf{Note (#1).}\itshape}{\par\medskip}
            \begin{note}{macros}
            This environment.
            \end{note}

            New paragraph.
            """#
        ).body
        #expect(
            html.contains(#"<p class="latex-noindent"><strong>Note (macros).</strong><em> This environment.</em></p>"#))
        #expect(html.contains("<p>New paragraph.</p>"))
        #expect(LaTeXConverter.convert(#"\textbf{Explicit }space."#).body.contains("<strong>Explicit </strong>space."))
    }

    @Test(
        "リストや引用・別行数式・コードの直後は、空行または par があるときだけ新しい段落を字下げする",
        arguments: [
            #"\begin{itemize}\item one\end{itemize}"#, #"\begin{quote}one\end{quote}"#, #"\[x=1\]"#,
            #"\begin{equation}x=1\end{equation}"#, "\\begin{verbatim}\none\n\\end{verbatim}",
        ])
    func paragraphContinues(after block: String) {
        let continuing = LaTeXConverter.convert(block + "\nContinues.\n\nNew.").body
        #expect(continuing.contains("<p class=\"latex-noindent\">Continues.</p>\n<p>New.</p>"))
        #expect(LaTeXConverter.convert(block + "\n\nNew.").body.contains("<p>New.</p>"))
        #expect(LaTeXConverter.convert(block + "\\par New.").body.contains("<p>New.</p>"))
    }

    @Test("クラスの判定はコメント・マクロ定義・実行されない条件に書かれた例を飛ばす")
    func classInfo() {
        let text = #"""
            % \documentclass{jsarticle}
            \newcommand{\example}{\documentclass[12pt]{report}}
            \iffalse\documentclass{ltjsbook}\fi
            \documentclass[twocolumn,11pt]{article}
            \begin{document}x\end{document}
            """#
        let info = LaTeXConverter.documentClassInfo(text)
        #expect(!info.isJapanese)
        #expect(!info.hasChapters)
        #expect(info.pointSize == 11)
        #expect(LaTeXConverter.convert(text).latexClass == info)
        let japanese = LaTeXConverter.documentClassInfo(#"\documentclass[12pt,book]{jlreq}"#)
        #expect(japanese.isJapanese && japanese.hasChapters)
        #expect(japanese.pointSize == 12)
        #expect(!LaTeXConverter.documentClassInfo(#"\documentclass{jmlr}"#).isJapanese)
        #expect(LaTeXConverter.documentClassInfo("unclassified").pointSize == 10)
    }
}
