import Foundation
import SurimonoCore
import Testing

/// amsthm, the bibliography and siunitx.
struct LaTeXPackageTests {
    private func body(_ latex: String) -> String { LaTeXConverter.convert(latex).body }

    @Test("\\newtheorem は節ごとの番号・共有する番号・番号なしを振り、\\ref は定理の番号を指す")
    func theoremNumbers() {
        let html = body(
            """
            \\documentclass{article}
            \\usepackage{amsthm}
            \\newtheorem{thm}{Theorem}[section]
            \\newtheorem{lem}[thm]{Lemma}
            \\newtheorem*{rem}{Remark}
            \\begin{document}
            \\section{A}
            \\begin{thm}[Euclid]\\label{t}There are infinitely many primes.\\end{thm}
            \\begin{lem}x\\end{lem}
            \\begin{rem}r\\end{rem}
            \\section{B}
            \\begin{thm}y\\end{thm}
            See Theorem~\\ref{t}.
            \\end{document}
            """)
        #expect(
            html.contains(
                "<div class=\"latex-theorem latex-theorem-plain\" id=\"thm-1\">\n<p><span class=\"theorem-head\">Theorem 1.1<span class=\"theorem-note\"> (Euclid)</span>.</span> There are infinitely many primes.</p>"
            ))
        #expect(html.contains("<span class=\"theorem-head\">Lemma 1.2.</span> x"))
        #expect(html.contains("<span class=\"theorem-head\">Remark.</span> r"))
        #expect(html.contains("<span class=\"theorem-head\">Theorem 2.1.</span> y"))
        #expect(html.contains("See Theorem&nbsp;<a href=\"#thm-1\">1.1</a>."))
    }

    @Test("\\theoremstyle は後の定理の見た目を決め、和文の文書は plain でも斜体にしない")
    func theoremStyles() {
        let english = body(
            "\\documentclass{article}\\usepackage{amsthm}\\theoremstyle{definition}\\newtheorem{defn}{Definition}"
                + "\\theoremstyle{remark}\\newtheorem{note}{Note}\\begin{document}\\begin{defn}d\\end{defn}"
                + "\\begin{note}n\\end{note}\\end{document}")
        #expect(english.contains("<div class=\"latex-theorem latex-theorem-definition\" id=\"thm-1\">"))
        #expect(english.contains("<div class=\"latex-theorem latex-theorem-remark\" id=\"thm-2\">"))
        let japanese = body(
            "\\documentclass{jsarticle}\\newtheorem{thm}{定理}\\begin{document}\\begin{thm}[ユークリッド]素数は無限にある。\\end{thm}\\end{document}"
        )
        #expect(
            japanese.contains(
                "<div class=\"latex-theorem latex-theorem-definition\" id=\"thm-1\">\n<p><span class=\"theorem-head\">定理 1（ユークリッド）</span> 素数は無限にある。</p>"
            ))
    }

    @Test("証明は見出しを付け、最後の段落の右に□を置く。式で終わるときは次の行に置く")
    func proofs() {
        let html = body("\\begin{proof}Easy.\\end{proof}\\begin{proof}[Sketch]$$x$$\\end{proof}")
        #expect(
            html.contains(
                "<div class=\"latex-proof\">\n<p><span class=\"proof-head\">Proof.</span> Easy.<span class=\"qed\">□</span></p>\n</div>"
            ))
        #expect(html.contains("<p><span class=\"proof-head\">Sketch.</span> </p>"))
        #expect(html.contains("</div>\n<p class=\"qed-line\"><span class=\"qed\">□</span></p>\n</div>"))
        let japanese = body(
            "\\documentclass{jsarticle}\\begin{document}\\begin{proof}略。\\end{proof}\\end{document}")
        #expect(japanese.contains("<span class=\"proof-head\">証明.</span> 略。"))
        let renamed = body(
            "\\documentclass{article}\\renewcommand{\\proofname}{Beweis}\\begin{document}\\begin{proof}q\\end{proof}\\end{document}"
        )
        #expect(renamed.contains("<span class=\"proof-head\">Beweis.</span> q"))
    }

    @Test("\\cite は thebibliography の番号やラベルにリンクし、補足を添える。ない文献はキーを太字で出す")
    func citations() {
        let html = body(
            "本文\\cite{a,b}と\\cite[p.~3]{a}と\\citep[see][ch.~2]{b}と\\cite{zz}。"
                + "\\begin{thebibliography}{9}\\bibitem{a} A. Author, \\emph{Book}. \\bibitem[Bo]{b} B. Writer.\\end{thebibliography}"
        )
        #expect(
            html.contains(
                "本文<span class=\"latex-cite\">[<a href=\"#bib-1-1\">1</a>, <a href=\"#bib-1-2\">Bo</a>]</span>"))
        #expect(html.contains("<span class=\"latex-cite\">[<a href=\"#bib-1-1\">1</a>, p.&nbsp;3]</span>"))
        #expect(html.contains("<span class=\"latex-cite\">[see <a href=\"#bib-1-2\">Bo</a>, ch.&nbsp;2]</span>"))
        #expect(html.contains("<span class=\"latex-cite\">[<span class=\"latex-missing\">zz</span>]</span>"))
        #expect(html.contains("<h2 class=\"latex-bibliography-heading\" id=\"bibliography-1\">References</h2>"))
        #expect(
            html.contains(
                "<li id=\"bib-1-1\"><span class=\"bib-label\">[1]</span>A. Author, <em>Book</em>.</li>\n<li id=\"bib-1-2\"><span class=\"bib-label\">[Bo]</span>B. Writer.</li>"
            ))
    }

    @Test("引用の補足の中の \\ref も番号にする")
    func referenceInCitationNote() {
        let html = body(
            "\\section{結果}\\label{s}\\cite[節~\\ref{s}]{a}"
                + "\\begin{thebibliography}{9}\\bibitem{a}Author.\\end{thebibliography}")
        #expect(html.contains("[<a href=\"#bib-1-1\">1</a>, 節&nbsp;<a href=\"#sec-1\">1</a>]"))
        #expect(!html.contains("\u{E000}"))
    }

    @Test("ラベルを付けた文献は番号を進めず、幅の引数がなくても最初の文献を読む")
    func labeledEntriesKeepTheNumbers() {
        let html = body(
            "\\cite{b,c}\\begin{thebibliography}{9}\\bibitem[A]{a}Alpha.\\bibitem{b}Beta.\\bibitem{c}Gamma.\\end{thebibliography}"
        )
        #expect(html.contains("[<a href=\"#bib-1-2\">1</a>, <a href=\"#bib-1-3\">2</a>]"))
        #expect(html.contains("<span class=\"bib-label\">[A]</span>Alpha."))
        let noWidth = body("\\cite{a}\\begin{thebibliography}\\bibitem{a}Alpha.\\end{thebibliography}")
        #expect(noWidth.contains("[<a href=\"#bib-1-1\">1</a>]"))
    }

    @Test("文献の見出しは和文なら参考文献、章のある文書クラスなら Bibliography、\\bibliography のファイルは読まない")
    func bibliographyHeadings() {
        let japanese = body(
            "\\documentclass{jsarticle}\\begin{document}\\begin{thebibliography}{9}\\bibitem{a}A\\end{thebibliography}\\end{document}"
        )
        #expect(japanese.contains(">参考文献</h2>"))
        let book = body(
            "\\documentclass{book}\\begin{document}\\begin{thebibliography}{9}\\bibitem{a}A\\end{thebibliography}\\end{document}"
        )
        #expect(book.contains(">Bibliography</h2>"))
        #expect(
            body("\\bibliography{refs}").contains("<div class=\"latex-unsupported\">refs.bib is not included</div>"))
    }

    @Test("\\num は 5 桁以上を 3 桁ずつ区切り、指数を × 10 の累乗に、マイナスを負号にする")
    func numbers() {
        #expect(body("\\num{12345.678}") == "<p>12\u{202F}345.678</p>\n")
        #expect(body("\\num{1234}") == "<p>1234</p>\n")
        #expect(body("\\num{-1.5e-4}") == "<p>−1.5 × 10<sup>−4</sup></p>\n")
        #expect(body("\\num{abc}") == "<p>abc</p>\n")
        #expect(body("\\num{1.2+-0.3}") == "<p>1.2 ± 0.3</p>\n")
    }

    @Test("\\qty と \\unit はマクロの単位を累乗で、文字の単位を書いたとおりに出す")
    func quantities() {
        #expect(
            body("\\qty{3.0e8}{\\metre\\per\\second}") == "<p>3.0 × 10<sup>8</sup>\u{202F}m\u{202F}s<sup>−1</sup></p>\n"
        )
        #expect(body("\\SI{9.8}{m/s^2}") == "<p>9.8\u{202F}m/s<sup>2</sup></p>\n")
        #expect(body("\\si{\\kilo\\gram\\metre\\per\\second\\squared}") == "<p>kg\u{202F}m\u{202F}s<sup>−2</sup></p>\n")
        #expect(body("\\unit{\\per\\square\\centi\\metre}") == "<p>cm<sup>−2</sup></p>\n")
        #expect(body("\\qty{25}{\\degreeCelsius}と\\qty{5}{\\percent}") == "<p>25\u{202F}°Cと5\u{202F}%</p>\n")
        #expect(body("\\ang{12;30;15}") == "<p>12°30′15″</p>\n")
    }

    @Test("数式の中の siunitx は SwaTex の数式に書き換え、引数のない \\qty はそのまま残す")
    func quantitiesInMath() {
        let html = body("$\\qty{3}{\\metre\\per\\second}$ と $\\num{1.2e3}$ と $\\SI{5}{\\micro\\metre}$")
        #expect(html.components(separatedBy: "<span class=\"math math-inline\">").count == 4)
        #expect(!html.contains("math-error"))
        #expect(body("$\\qty(x)$").contains("<code class=\"math-error\">$\\qty(x)$</code>"))
        #expect(!body("\\begin{proof}\\[x\\qedhere\\]\\end{proof}").contains("math-error"))
    }
}

struct LaTeXPackageBoundaryTests {
    private func body(_ latex: String) -> String { LaTeXConverter.convert(latex).body }

    @Test("見出しで自分や互いの環境を開く定理も、決まった回数で読み終える", .timeLimit(.minutes(1)))
    func theoremHeadingsThatOpenThemselves() {
        #expect(body("\\newtheorem{loop}{\\begin{loop}\\end{loop}}\\begin{loop}x\\end{loop}").contains("x"))
        let mutual = body(
            "\\newtheorem{a}{\\begin{b}\\end{b}\\begin{b}\\end{b}}\\newtheorem{b}{\\begin{a}\\end{a}\\begin{a}\\end{a}}"
                + "\\begin{a}本文\\end{a}")
        #expect(mutual.contains("本文"))
    }

    @Test("前の定理を二度ずつ開く見出しを重ねても、見出しは倍々に長くならない", .timeLimit(.minutes(1)))
    func theoremHeadingsThatDouble() {
        var source = "\\newtheorem{t0}{X}"
        for level in 1...30 {
            let previous = "\\begin{t\(level - 1)}\\end{t\(level - 1)}"
            source += "\\newtheorem{t\(level)}{\(previous)\(previous)}"
        }
        for level in 0...30 { source += "\\begin{t\(level)}本文\(level)\\end{t\(level)}" }
        let html = body(source)
        #expect(html.contains("本文30"))
        #expect(html.count < 5_000_000)
    }

    @Test("長い見出しを何度も出し、見出しから多くの定理を開いても、見出しの合計は決まった大きさまで", .timeLimit(.minutes(1)))
    func longTheoremHeadings() {
        let long = String(repeating: "見", count: 30_000)
        let repeated = body(
            "\\newtheorem{x}{\(long)}" + String(repeating: "\\begin{x}本文\\end{x}", count: 1_000))
        #expect(repeated.contains("本文"))
        #expect(repeated.utf8.count < 10_000_000)
        let opening = body(
            "\\newtheorem{y}{\(String(repeating: "y", count: 900))}\\newtheorem{z}{"
                + String(repeating: "\\begin{y}\\end{y}", count: 1_000) + "}"
                + String(repeating: "\\begin{z}本文\\end{z}", count: 1_000))
        #expect(opening.contains("本文"))
        #expect(opening.utf8.count < 10_000_000)
    }

    @Test("長いラベルを何度も引いても、引用は決まった大きさで作るのをやめてキーを出す", .timeLimit(.minutes(1)))
    func longLabelsCitedManyTimes() {
        let label = String(repeating: "L", count: 100_000)
        let keys = Array(repeating: "a", count: 100_000).joined(separator: ",")
        let once = body(
            "\\cite{\(keys)}\\begin{thebibliography}{9}\\bibitem[\(label)]{a}A.\\end{thebibliography}")
        #expect(once.utf8.count < 2_000_000)
        let label15k = String(repeating: "M", count: 15_000)
        let many = body(
            String(repeating: "\\cite{a}", count: 300)
                + "\\begin{thebibliography}{9}\\bibitem[\(label15k)]{a}A.\\end{thebibliography}")
        #expect(many.utf8.count < 5_000_000)
        #expect(many.contains("<span class=\"latex-cite\">[a]</span>"))
    }

    @Test("上限を超えるラベルを別々の引用から何度も引くと、どの引用もキーを書いたとおりに出す", .timeLimit(.minutes(1)))
    func longLabelCitedSeparately() {
        let html = body(
            String(repeating: "\\cite{a}", count: 1_000) + "\\begin{thebibliography}{9}\\bibitem["
                + String(repeating: "L", count: 100_000) + "]{a}A.\\end{thebibliography}")
        #expect(html.components(separatedBy: "<span class=\"latex-cite\">[a]</span>").count == 1_001)
        #expect(html.utf8.count < 1_000_000)
    }

    @Test("定理の見出しの中の引用は、何度出ても決まった大きさまで", .timeLimit(.minutes(1)))
    func citationsInRepeatedHeadings() {
        let label = String(repeating: "M", count: 15_000)
        let headings = body(
            "\\newtheorem{x}{\\cite{a}}" + String(repeating: "\\begin{x}本文\\end{x}", count: 2_000)
                + "\\begin{thebibliography}{9}\\bibitem[\(label)]{a}A.\\end{thebibliography}")
        #expect(headings.utf8.count < 10_000_000)
    }

    @Test("自分や互いを引く文献のラベルも、引く回数が増えるラベルも、決まった大きさで引用を埋める", .timeLimit(.minutes(1)))
    func citationsInLabels() {
        let selfCiting = body(
            "\\cite{a}\\begin{thebibliography}{9}\\bibitem[{\\cite{a}}]{a}Author.\\end{thebibliography}")
        #expect(!selfCiting.contains("\u{E000}"))
        let mutual = body(
            "\\cite{a}\\begin{thebibliography}{9}\\bibitem[{\\cite{b}}]{a}A.\\bibitem[{\\cite{a}}]{b}B.\\end{thebibliography}"
        )
        #expect(!mutual.contains("\u{E000}"))
        var entries = "\\bibitem{e0}E."
        for level in 1...30 {
            let previous = "e\(level - 1)"
            entries += "\\bibitem[{\\cite{\(previous),\(previous),\(previous),\(previous)}}]{e\(level)}E."
        }
        let growing = body("\\cite{e30}\\begin{thebibliography}{9}\(entries)\\end{thebibliography}")
        #expect(growing.count < 10_000_000)
        #expect(!growing.contains("\u{E000}"))
    }

    @Test("± が何度も続く数は、組み立てずに書いたとおりに出す", .timeLimit(.minutes(1)))
    func repeatedUncertainties() {
        let source = String(repeating: "1+-", count: 10_000) + "1"
        #expect(body("\\num{\(source)}").contains("1+-1+-1"))
        #expect(body("$\\num{\(source)}$後").contains("後"))
        #expect(body("\\num{1.2 \\pm 0.3}") == "<p>1.2 ± 0.3</p>\n")
    }

    @Test("引数の足りない \\qty が入れ子になっても、引数を写し直さない", .timeLimit(.minutes(1)))
    func nestedQuantitiesMissingTheUnit() {
        let depth = 20_000
        let source = "$" + String(repeating: "\\qty{", count: depth) + "1" + String(repeating: "}", count: depth) + "$後"
        #expect(body(source).contains("後"))
    }

    @Test("長い数も、閉じていない数式の引数も、長さに比例する時間で読む", .timeLimit(.minutes(1)))
    func longNumbersAndUnclosedArguments() {
        #expect(body("\\num{1234567}") == "<p>1\u{202F}234\u{202F}567</p>\n")
        let digits = body("\\num{\(String(repeating: "1", count: 300_000))}")
        #expect(digits.count > 300_000)
        let unclosed = body("$" + String(repeating: "\\num{", count: 20_000) + "$後")
        #expect(unclosed.contains("後"))
    }
}
