import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXTypesettingTests {
    @Test("multline は左・中央・右に組み、星付きでも行揃えを保つ", arguments: ["multline", "multline*"])
    func multlineAlignment(environment: String) {
        let html = LaTeXConverter.convert("\\begin{\(environment)}a+b\\\\=c\\\\=d\\end{\(environment)}").body
        let alignments = html.components(separatedBy: "justify-content: ").dropFirst().map {
            $0.prefix(while: { $0 != ";" })
        }
        #expect(alignments.map(String.init) == ["left", "center", "right"])
        #expect(html.contains(#"class="latex-multline-number">(1)</span>"#) == (environment == "multline"))
        #expect(!html.contains("math-error"))
    }

    @Test("既定の任意引数を持つ命令は、使った場所だけ展開して無関係な式の字形を変えない")
    func optionalMacros() throws {
        let source =
            #"\newcommand{\greet}[2][friend]{Hello, #1 #2!}\newcommand{\power}[2][2]{#2^{#1}}$x+1$\[y=2\]$\power{z}+\power[3]{w}$\greet{Ann}"#
        let result = LaTeXConverter.convert(source)
        let inline = try #require(MathRenderer.html("x+1", display: false))
        let display = try #require(MathRenderer.html("y=2", display: true))
        #expect(result.body.contains(inline))
        #expect(result.body.contains(display))
        #expect(result.body.contains(#"aria-label="z^{2}+w^{3}""#))
        #expect(result.body.contains("Hello, friend Ann!"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("本文と数式で同じ ensuremath マクロを使うとどちらも対の数式を描く")
    func ensureMath() {
        let source = #"\newcommand{\pair}[2]{\ensuremath{\langle #1, #2 \rangle}}\pair{x}{y} and $\pair{a}{b}$"#
        let result = LaTeXConverter.convert(source)
        #expect(result.body.components(separatedBy: "math math-inline").count == 3)
        #expect(!result.body.contains("math-error"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("描けない数式は前方参照の有無にかかわらず原文を残し確認欄にも出す")
    func brokenMath() {
        let result = LaTeXConverter.convert(
            #"$\surimonoUndefined$ \[\ref{s}+\surimonoUndefined\]\section{Next}\label{s}"#)
        #expect(result.body.components(separatedBy: "math-error").count == 3)
        #expect(result.readingIssues.filter { $0.contains("surimonoUndefined") }.count == 2)
    }

    @Test("異なる未対応の式は八件を超えても確認でき、同じ式は一度だけ報告する")
    func reportsEachFailedFormula() {
        let expressions = (1...12).map { "$\\unknown{\($0)}$" }
        let result = LaTeXConverter.convert((expressions + expressions).joined(separator: " "))
        #expect(result.readingIssues.count == expressions.count)
        for source in expressions { #expect(result.readingIssues.contains { $0.contains(source) }) }
    }

    @Test("表題と著者の謝辞に星と短剣を振り、本文の脚注は一から始まる")
    func titleThanks() {
        let result = LaTeXConverter.convert(
            #"\title{Paper\thanks{First}}\author{A\thanks{Second} and B\thanks{Third}}\maketitle Body\footnote{Main}"#)
        for mark in ["*", "†", "‡"] { #expect(result.body.contains(">\(mark)</a></sup>")) }
        for (mark, text) in [("*", "First"), ("†", "Second"), ("‡", "Third")] {
            #expect(result.body.contains("<p><sup class=\"latex-symbolic-note\">\(mark)</sup>&nbsp;\(text)</p>"))
        }
        #expect(result.body.contains(##"id="fnref-1">1</a>"##))
        #expect(result.body.contains(##"<li id="fn-1" value="1"><p>Main</p>"##))
    }

    @Test("各種 TeX ロゴは文字を残して字ごとの組版を選ぶ")
    func logos() {
        let result = LaTeXConverter.convert(#"\TeX{} / \LaTeX{} / \LaTeXe{} / \BibTeX{}"#)
        #expect(result.body.components(separatedBy: #"class="latex-logo""#).count == 5)
        #expect(result.body.components(separatedBy: #"class="latex-logo-e""#).count == 5)
        #expect(result.body.components(separatedBy: #"class="latex-logo-a""#).count == 3)
        #expect(result.body.contains("latex-logo-ib"))
        #expect(result.body.contains("latex-logo-epsilon"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("装飾を含む手書きの式番号も右端に組み、入れ子の括弧を数式本体に残さない")
    func styledEquationTags() {
        let html = LaTeXConverter.convert(#"\begin{align}x&=y\tag{\textbf{AB}}\\y&=z\tag*{OK}\end{align}"#).body
        #expect(html.contains(#"aria-label="\begin{aligned}x&amp;=y\\y&amp;=z\end{aligned}""#))
        #expect(html.contains(#"aria-label="\tag{\textbf{AB}}""#))
        #expect(html.contains(#"font-weight="bold""#))
        #expect(html.contains(#"%">OK</span>"#))
        #expect(!html.contains("math-error"))
    }

    @Test("align・gather の番号は SVG の外で行に対応し、番号無しの行と式の参照を区別する")
    func alignedNumbers() {
        let result = LaTeXConverter.convert(
            #"\begin{align}a&=1\\b&=2\nonumber\\c&=\frac{1}{2}\label{c}\end{align}\begin{gather}x\\y\end{gather}\begin{multline}p\\q\end{multline}\eqref{c}"#
        )
        let html = result.body
        #expect(html.components(separatedBy: "latex-row-number").count == 5)
        for n in 1...4 { #expect(html.contains("%\">(\(n))</span>")) }
        #expect(html.contains(#"class="latex-multline-number">(5)</span>"#))
        #expect(html.contains(##"<a class="latex-number-ref" href="#eq-2">(2)</a>"##))
        #expect(!html.contains(#"\tag{"#))
        #expect(result.readingIssues.isEmpty)
    }
}
