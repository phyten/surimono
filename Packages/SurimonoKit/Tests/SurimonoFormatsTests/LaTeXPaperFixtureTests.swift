import SurimonoFormats
import Testing

struct LaTeXPaperFixtureTests {
    @Test("欧文クラスの和文論文は指定された名称・本文幅・書体・大小の表題を持つ")
    func paper() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[a4paper,11pt]{article}
            \usepackage[margin=25mm]{geometry}
            \usepackage{fontspec}
            \setmainfont[BoldFont={YuMincho Demibold}]{YuMincho}
            \XeTeXlinebreaklocale "ja"
            \renewcommand{\abstractname}{要旨}
            \renewcommand{\figurename}{図}
            \renewcommand{\tablename}{表}
            \renewcommand{\refname}{参考文献}
            \title{紙片の折り目を数える\\\large 折り方の比較}
            \author{青木\\\small 紙工房\and 森\\\small 資料室}
            \date{}
            \begin{document}
            \maketitle
            \begin{abstract}二種類の紙を折った。\end{abstract}
            \noindent\textbf{キーワード：}紙
            \begin{table}\caption{紙の厚さ}\end{table}
            \begin{figure}\caption{折り目}\end{figure}
            \begin{thebibliography}{1}\bibitem{a}折り紙の記録\end{thebibliography}
            \appendix\section{記録票}\label{app}付録\ref{app}。
            \end{document}
            """#, fontIndex: .testInventory)
        let info = try #require(fragment.latexClass)
        #expect(fragment.language == "ja")
        #expect(!info.isJapanese)
        #expect(info.styleVariables.contains("--latex-text-width: 160mm"))
        #expect(info.styleVariables.contains("YuMincho"))
        #expect(info.localFontFaces.contains(#"local("YuMincho Demibold")"#))
        let html = fragment.body
        for label in ["要旨", "表 1", "図 1", "参考文献"] { #expect(html.contains(">\(label)<")) }
        #expect(html.contains("紙片の折り目を数える<br"))
        #expect(html.contains("var(--latex-size-large, 1.2rem)"))
        #expect(html.contains("var(--latex-size-small, 0.9rem)"))
        #expect(html.components(separatedBy: #"class="latex-author-name latex-front-author""#).count == 3)
        #expect(!html.contains("latex-date"))
        #expect(html.contains(#"<p class="latex-noindent"><strong>キーワード：</strong>"#))
        #expect(html.contains(##"href="#sec-A">A</a>"##))
        #expect(fragment.readingIssues.isEmpty)
    }
}
