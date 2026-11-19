import Testing

@testable import SurimonoFormats

struct LaTeXRegisterDepthTests {
    @Test("名前付きレジスタと番号によるレジスタを更新して繰り返し本文を読む")
    func primitiveRegisters() {
        let source = #"""
            \documentclass{article}\newcount\labelno\labelno=1
            \begin{document}\count12=12\divide\count12 by 5\multiply\count12 by 3
            \loop\textbf{Box \the\labelno}\ifodd\labelno odd\else even\fi\par
            \advance\labelno by 1\ifnum\labelno<4 \repeat
            {\count12=7\number\count12}/\the\count12\end{document}
            """#
        let result = LaTeXConverter.convert(source)
        for (index, kind) in [(1, "odd"), (2, "even"), (3, "odd")] {
            #expect(result.body.contains("<strong>Box \(index)</strong>\(kind)"))
        }
        #expect(result.body.contains("7/6"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("カーネルのリストと数値条件をマクロから展開して各項目を組む")
    func kernelLoops() {
        let source = #"""
            \documentclass{article}\makeatletter
            \def\stations{Red,{Green,Blue},Gold}
            \newcommand{\labels}{\@for\station:=\stations\do{\station\ shelf\par}}
            \newcommand{\tick}{\@whilenum\count4<4\do{[\the\count4]\advance\count4 by 2}}
            \makeatother\begin{document}\labels\tick\end{document}
            """#
        let result = LaTeXConverter.convert(source)
        for text in ["Red shelf", "Green,Blue shelf", "Gold shelf", "[0][2]"] {
            #expect(result.body.contains(text))
        }
        #expect(result.readingIssues.isEmpty)
    }

    @Test("整数式と寸法式は演算順序と丸めを保って比較やカウンターに渡す")
    func expressions() {
        let source = #"""
            \newcounter{row}\setcounter{row}{\numexpr 2*(7-3)+5/2\relax}
            \ifnum\value{row}=11A\else X\fi
            \ifdim\dimexpr 1in-72.27pt+2pt*3\relax<6pt B\else X\fi
            \the\dimexpr 1pt/2\relax/\number\numexpr -5/2\relax
            """#
        let result = LaTeXConverter.convert(source)
        #expect(result.body.contains("AB0.5pt/-3"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("数式でも繰り返しの各回のレジスタと式を読んで字下げには寸法式を使う")
    func registersInMathAndLengths() {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{article}\setlength{\parindent}{\dimexpr 3pt*2\relax}
            \begin{document}\count2=1\loop $x=\number\numexpr\count2+2\relax$
            \advance\count2 by 1\ifnum\count2<3 \repeat\end{document}
            """#)
        #expect(result.body.contains(#"aria-label="x=3""#))
        #expect(result.body.contains(#"aria-label="x=4""#))
        #expect(result.latexClass?.styleVariables.contains("--latex-parindent: 6") == true)
        #expect(result.readingIssues.isEmpty)
    }

    @Test("計算が成立しない代入や無限ループでも変換は終了し後続の文字が残る")
    func bounds() {
        let result = LaTeXConverter.convert(#"\count0=5\divide\count0 by 0\the\count0\@whilenum1=1\do{}TAIL"#)
        #expect(result.body.contains("5TAIL"))
        #expect(result.readingIssues == ["LaTeX expansion limit reached"])
    }

    @Test("章のある文書は段落以下にも番号を付けられ各目次は要求時の深さまでを載せる")
    func independentDepths() {
        let source = #"""
            \documentclass{report}\begin{document}
            \setcounter{secnumdepth}{5}\setcounter{tocdepth}{1}\tableofcontents
            \setcounter{tocdepth}{3}\tableofcontents\chapter{Machines}\section[Keys]{Long key list}
            \subsection{Locks}\subsubsection{Brass}\paragraph{Finish}\subparagraph{Edges}
            \appendix\chapter{Spare parts}\label{spares}\ref{spares}\end{document}
            """#
        let result = LaTeXConverter.convert(source)
        let chunks = result.body.components(separatedBy: "</nav>")
        #expect(chunks.count == 3)
        guard chunks.count == 3 else { return }
        #expect(chunks[0].contains("Keys") && !chunks[0].contains("Locks"))
        #expect(chunks[1].contains("Brass") && !chunks[1].contains("Finish"))
        #expect(chunks[2].contains("1.1.1.1.1.1</span>Edges"))
        #expect(chunks[2].contains("Long key list") && chunks[2].contains(">A</a>"))
    }

    @Test("番号を付けない深さの節も星がなければ目次に載せる")
    func unnumberedToc() {
        let result = LaTeXConverter.convert(
            #"\setcounter{secnumdepth}{0}\tableofcontents\section{Shown}\section*{Hidden}"#)
        let toc = result.body.components(separatedBy: "</nav>")[0]
        #expect(toc.contains("Shown") && !toc.contains("Hidden"))
        #expect(!result.body.contains("class=\"secnum\""))
    }
}
