import Testing

@testable import SurimonoFormats

struct LaTeXClassLanguageTests {
    @Test("和文クラスの証明とリストの名前はパッケージ既定を使い、明示した名前を優先する")
    func packageNames() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{ltjsarticle}\usepackage{amsthm,listings}\begin{document}
            \begin{proof}甲\end{proof}
            \begin{lstlisting}[caption=見本]
            x
            \end{lstlisting}
            \renewcommand{\proofname}{証}\renewcommand{\lstlistingname}{例}
            \begin{proof}乙\end{proof}
            \begin{lstlisting}[caption=見本]
            y
            \end{lstlisting}
            \end{document}
            """#)
        for name in ["Proof.", "Listing 1", "証.", "例 2"] { #expect(fragment.body.contains(">\(name)</span>")) }
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("和文記事の付録は節と参照に付録名を付け、小節は A.1 から始まる", arguments: ["jsarticle", "ltjsarticle"])
    func appendix(_ className: String) {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{\#(className)}\begin{document}\tableofcontents\appendix\section{末尾}\label{a}\subsection{表}\paragraph{注意}項目。\ref{a}\end{document}"#
        )
        #expect(fragment.body.contains(">付録 A</span>末尾"))
        #expect(fragment.body.contains(">付録 A</a>"))
        #expect(fragment.body.contains(">A.1</span>表"))
        #expect(fragment.body.contains(">■注意</h"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("スペイン語 babel の節と目次に終止点を付け、参照と無効化指定では付けない")
    func spanishPunctuation() {
        func html(_ options: String) -> String {
            LaTeXConverter.convert(
                #"\documentclass{article}\usepackage[\#(options)]{babel}\begin{document}\tableofcontents\section{Luz}\label{l}\ref{l}\end{document}"#
            ).body
        }
        let fragment = html("spanish")
        #expect(fragment.components(separatedBy: ">1.</span>Luz").count == 3)
        #expect(fragment.contains(">1</a>"))
        #expect(!html("spanish,es-nosectiondot").contains(">1.</span>"))
    }

    @Test("記事の目次では節にだけ節の印を付け、図表一覧に混ぜない")
    func contentsLevels() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{ltjsarticle}\begin{document}\tableofcontents\listoffigures\listoftables\section{節}\subsection{小節}\begin{figure}\caption{図題}\end{figure}\begin{table}\caption{表題}\end{table}\end{document}"#
        ).body
        let lists = fragment.components(separatedBy: "</nav>")
        #expect(lists.count == 4)
        #expect(fragment.components(separatedBy: "latex-toc-section").count == 2)
        #expect(lists[0].contains("latex-toc-section"))
    }
}
