import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXSocietyBodyTests {
    @Test("学会誌の見出し番号は本文の参照と表示上の終止点を区別し、小見出しは独立した行にする")
    func sections() {
        let source = #"""
            \begin{document}
            \section{方法}\label{method}\subsection{前半}\subsection{後半}\paragraph{厚紙}
            \ref{method}章。\end{document}
            """#
        for (name, sub, paragraph, reference) in [
            ("ipsj", "1.2", "1.2.0.1", ">1</a>章"),
            ("ieicej", "1. 2", "a )", ">1.</a>章"),
            ("ieice", "1.2", "(1)", ">1</a>章"),
        ] {
            let html = LaTeXConverter.convert("\\documentclass[paper]{\(name)}" + source).body
            let box = name == "ieicej" ? #"<span class="latex-heading-measure">"# : ""
            #expect(html.contains(#"<span class="secnum">1.</span>"# + box + "方法"))
            #expect(html.contains("<span class=\"secnum\">\(sub)</span>" + box + "後半"))
            #expect(html.contains("<span class=\"secnum\">\(paragraph)</span>" + box + "厚紙"))
            #expect(html.contains(reference))
            #expect(!html.contains("latex-runin"))
        }
    }

    @Test("学会誌の図表と参考文献にはクラスの名称と角括弧の番号を付ける")
    func labels() {
        let source = #"""
            \begin{document}
            \begin{figure}\caption{試験溝}\end{figure}
            \begin{table}\caption{厚紙}\end{table}
            \begin{thebibliography}{9}\bibitem{a}Entry.\end{thebibliography}\end{document}
            """#
        for (name, figure, table, references) in [
            ("ipsj", "図 1", "表 1", "参考文献"), ("ieicej", "図 1", "表 1", "文献"),
            ("ieice", "Fig. 1", "Table 1", "References"),
        ] {
            let html = LaTeXConverter.convert("\\documentclass{\(name)}" + source).body
            let text = DocumentOutline.plainText(ofHTML: html)
            #expect(text.contains(figure + "試験溝"))
            #expect(text.contains(table + "厚紙"))
            if name == "ieicej" {
                #expect(html.contains(#"<span class="latex-heading-measure">文献</span>"#))
                #expect(html.contains(#"<span class="latex-heading-measure">試験溝</span>"#))
            } else {
                #expect(html.contains(">" + references + "</h2>"))
            }
            #expect(html.contains(#"<span class="bib-label">[1]</span>"#))
        }
    }

    @Test("引用の各番号を角括弧で囲んで番号順に並べ、圧縮するクラスだけが三連番以上を範囲にする")
    func citations() {
        let source = #"""
            \begin{document}
            A\cite{c,a,b}B\cite{c,a}C\cite{b,a}D.
            \begin{thebibliography}{9}\bibitem{a}A.\bibitem{b}B.\bibitem{c}C.\end{thebibliography}\end{document}
            """#
        for (name, expected) in [
            ("ipsj", "A[1], [2], [3]B[1], [3]C[1], [2]D"),
            ("ieicej", "A[1]〜[3]B[1],[3]C[1],[2]D"),
            ("ieice", "A[1]–[3]B[1], [3]C[1], [2]D"),
        ] {
            let html = LaTeXConverter.convert("\\documentclass{\(name)}" + source).body
            #expect(DocumentOutline.plainText(ofHTML: html).contains(expected))
            #expect(html.contains(##"<a href="#bib-1-3">3</a>"##))
        }
    }

    @Test("学会誌の箇条書きは各項目の先頭に印を一つ置き、段をまたぐ文字を複製しない")
    func itemMarks() {
        for name in ["ipsj", "ieicej", "ieice"] {
            let source =
                #"\begin{document}\begin{itemize}\item First\item Second\item Third\end{itemize}\end{document}"#
            let html = LaTeXConverter.convert("\\documentclass{\(name)}" + source).body
            for word in ["First", "Second", "Third"] {
                #expect(html.contains("</span>" + word + "</li>"))
            }
            #expect(html.components(separatedBy: #"<span class="latex-item-mark">•</span>"#).count == 4)
            #expect(html.components(separatedBy: "<li>").count == 4)
        }
    }

    @Test("本文の脚注は参照と注で印を一致させ、列挙には各学会誌の括弧を使う")
    func marks() {
        for (name, note, marker) in [("ipsj", "*1", "(1)"), ("ieicej", "（注1）", "（1）"), ("ieice", "∗", "1.")] {
            let source = #"""
                \begin{document}\maketitle 本文\footnote{紙。}
                \begin{enumerate}\item 項目\end{enumerate}\end{document}
                """#
            let html = LaTeXConverter.convert("\\documentclass{\(name)}" + source).body
            #expect(html.contains(">" + note + "</a></sup>"))
            let bearings = name == "ieicej" ? " data-latex-tight-parentheses" : ""
            #expect(html.contains("<sup" + bearings + #" class="latex-symbolic-note">"# + note + "</sup>"))
            #expect(html.contains("<sup" + bearings + #" class="footnote-ref">"#))
            #expect(html.contains(#"<span class="item-label">"# + marker + "</span>"))
        }
    }
}
