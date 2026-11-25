import Foundation
import Synchronization
import Testing

@testable import SurimonoCore

extension FinderPreviewTests {
    private func mathPreview(_ source: String, suffix: String) throws -> String {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("paper." + suffix)
            try Data(source.utf8).write(to: file)
            return FinderPreview.make(for: file).html
        }
    }

    @Test("千個の短い数式をすべて SVG にして末尾の本文まで読める", arguments: ["md", "tex"])
    func thousandFormulas(_ suffix: String) throws {
        let paper = (0..<1_000).map { "$\($0)$" }.joined(separator: " ")
        let body = paper + "\n\nEnd of paper."
        let html = try mathPreview(
            suffix == "tex" ? "\\begin{document}" + body + "\\end{document}" : body, suffix: suffix)
        #expect(html.components(separatedBy: "<svg ").count - 1 == 1_000)
        #expect(html.contains("End of paper."))
    }

    @Test("組版時間を使い切っても文書の期限までは本文を読み続ける")
    func exhaustedMathTime() throws {
        let start = ContinuousClock.now
        let time = Mutex(start)
        // Let time pass during each real renderer call, without depending on machine speed.
        let request = PreviewConversion(deadline: start + .seconds(5)) {
            time.withLock { instant in
                instant += .milliseconds(25)
                return instant
            }
        }
        try PreviewConversion.$current.withValue(request) {
            #expect(MathRenderer.html("x", display: false) != nil)
            var drawn = 0
            while drawn < 100, MathRenderer.html("y", display: false) != nil { drawn += 1 }
            #expect(drawn > 0 && drawn < 100)
            try PreviewConversion.check()
            time.withLock { $0 = start + .seconds(5) }
            #expect(throws: CancellationError.self) { try PreviewConversion.check() }
        }
    }

    @Test("本文と定義が単独の上限を超えた式だけ原文に戻す")
    func oversizedFormula() throws {
        let expression = String(repeating: "x+", count: 2_048) + "y"
        let html = try mathPreview("Before $a$ and $\(expression)$ and $b$ after.", suffix: "md")
        #expect(html.contains("<code class=\"math-error\">$\(expression)$</code>"))
        #expect(html.components(separatedBy: "<svg ").count - 1 == 2)
        #expect(html.contains("after."))
    }

    @Test("文書の数式予算を使い切ると後続の式を原文で示して最後まで読む")
    func exhaustedMathBudget() throws {
        let limit = PreviewConversion.maximumFormulaBytes
        let count = PreviewConversion.maximumMathBytes / limit
        // Spaces count as input, but keep layout and the generated SVG small.
        let formula = "$$x" + String(repeating: " ", count: limit - 1) + "$$"
        let displays = Array(repeating: formula, count: count).joined(separator: "\n\n")
        let html = try mathPreview(displays + "\n\nHere is $y$.\n\n$$z$$\n\nLast paragraph.", suffix: "org")
        #expect(html.components(separatedBy: "<svg ").count - 1 == count)
        #expect(html.contains("Here is <code class=\"math-error\">$y$</code>."))
        #expect(html.contains("<pre class=\"math-error\">$$z$$</pre>"))
        #expect(html.contains("Last paragraph."))
    }

    @Test("大きな定義表から式が使う定義だけを渡し、過大な定義を使う式だけ原文に戻す", arguments: ["org", "tex"])
    func selectedMathMacros(_ suffix: String) throws {
        let padding = String(repeating: "z", count: PreviewConversion.maximumFormulaBytes)
        let assignments = [
            #"\def\giant{"# + padding + "}", #"\def\smallop{x}"#, #"\def\wrapper{\smallop}"#,
            #"\def\depends{\giant}"#,
        ]
        let definitions =
            suffix == "org" ? "#+LATEX_HEADER: " + assignments.joined() : assignments.joined(separator: "\n")
        let body = #"Before $a$ then $\wrapper$ and $\depends$ and $b$ after."#
        let source = definitions + "\n\n" + (suffix == "org" ? body : "\\begin{document}" + body + "\\end{document}")
        let html = try mathPreview(source, suffix: suffix)
        #expect(html.components(separatedBy: "<svg ").count - 1 == 3)
        #expect(html.contains(#"<code class="math-error">$\depends$</code>"#))
        #expect(html.contains("after."))
    }

    @Test("定義と式本文の合計が境界に収まる式を組み、超えた式の後も組版を続ける")
    func combinedMathBytes() throws {
        let formula = #"\tinyop"#
        let definition = #"\def\tinyop{x}"#
        let count = PreviewConversion.maximumFormulaBytes - definition.utf8.count - formula.utf8.count
        let padded = String(definition.dropLast()) + String(repeating: " ", count: count) + "}"
        let html = try mathPreview(
            "#+LATEX_HEADER: \(padded)\n\n$\(formula)$ and $\(formula)+1$ and $z$.", suffix: "org")
        #expect(html.components(separatedBy: "<svg ").count - 1 == 2)
        #expect(html.contains(#"<code class="math-error">$\tinyop+1$</code>"#))
    }

    @Test("原文表示の数式にも番号とリンク先が付き後続の番号と前方参照がつながる")
    func fallbackEquationNumbers() throws {
        let oversized = String(repeating: "x+", count: 2_048) + "y"
        let source = #"""
            \begin{document}
            See \eqref{large} and \eqref{next}. The next number is $\ref{next}$.
            \begin{equation}\label{large}\#(oversized)\end{equation}
            \begin{equation}\label{next}y=2\end{equation}
            Done.
            \end{document}
            """#
        let html = try mathPreview(source, suffix: "tex")
        #expect(html.contains(#"<pre class="math-error">"#))
        for n in 1...2 {
            #expect(html.contains("id=\"eq-\(n)\""))
            #expect(html.contains("href=\"#eq-\(n)\">(\(n))</a>"))
            #expect(html.contains("class=\"eqno\">(\(n))</span>"))
        }
        #expect(html.contains(#"class="math math-inline""#))
        #expect(html.contains("Done."))
    }
}
