import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXExamTests {
    private func exam(_ body: String, options: String = "", preamble: String = "") -> HTMLFragment {
        LaTeXConverter.convert("\\documentclass[\(options)]{exam}\(preamble)\\begin{document}\(body)\\end{document}")
    }

    @Test("実線と点線の書き込み欄は宣言時点の罫間隔と太さを別々に保持する")
    func answerLines() {
        let html = exam(
            #"\fillwithlines{18mm}\setlength{\linefillheight}{12pt}\linefillthickness=.4pt\fillwithlines{25mm}\fillwithdottedlines{25mm}"#,
            preamble: #"\setlength{\dottedlinefillheight}{10pt}"#
        ).body
        #expect(html.ranges(of: "<svg data-exam-rules ").count == 3)
        #expect(html.contains("font-size: calc(18.0675 *"))
        #expect(html.contains("font-size: calc(12 *"))
        #expect(html.contains("stroke-width: calc(0.4 *"))
        #expect(html.contains("font-size: calc(10 *"))
        #expect(html.contains("stroke-dasharray:"))
    }

    @Test("試験の設問数・合計点を先に参照し、解答欄の寸法と横の採点表を組む")
    func corpus() throws {
        let result = exam(
            #"""
            Questions: \numquestions; points: \numpoints.\gradetable[h]
            \begin{questions}\question[2] First fold.\fillwithlines{18mm}
            \question[3] Tilted rail.\fillwithlines{25mm}\end{questions}
            """#, preamble: #"\addpoints"#)
        let html = result.body
        #expect(html.contains("Questions: 2; points: 5."))
        #expect(html.contains("<td>Question:</td><td>1</td><td>2</td><td>Total</td>"))
        #expect(html.contains("<td>Points:</td><td>2</td><td>3</td><td>5</td>"))
        #expect(html.contains("<td>Score:</td><td></td><td></td><td></td>"))
        for (length, bp) in [(18, 51.024), (25, 70.866)] {
            let css = try #require(LaTeXSymbols.printLength("\(length)mm"))
            #expect(html.contains("style=\"height: \(css)\""))
            let mm = try #require(LaTeXPageSettings.millimetres("\(length)mm"))
            #expect(abs(mm * 72 / 25.4 - bp) < 0.001)
        }
        #expect(html.contains(#"data-exam-credit="2">1.</span> (2 points) First fold."#))
        #expect(!html.contains("18mm") && !html.contains("25mm"))
        let box = try #require(result.latexClass?.pageBox)
        #expect(abs(box.left - 72) < 0.001 && abs(box.top - 72) < 0.001)
        #expect(abs(box.paperWidth - box.left - box.right - 468) < 0.001)
    }

    @Test("小問・枝問の点を親の設問に足し、選択肢と解答欄の正答は解答版だけに刷る")
    func answers() {
        let source = #"""
            \ifprintanswers Key edition.\else Practice edition.\fi\begin{questions}\question Describe.\begin{parts}\part[1] First.
            \begin{subparts}\subpart[2\half] Second.\end{subparts}\end{parts}
            \begin{choices}\choice Cedar\CorrectChoice Maple\end{choices}
            \begin{oneparchoices}\choice Pine\choice Oak\end{oneparchoices}
            \begin{checkboxes}\choice Blue\CorrectChoice Green\end{checkboxes}
            \fillin[Correct entry][17mm]\begin{solution}[9mm]SOLUTION-KEY\end{solution}
            \makeemptybox{4mm}\fillwithdottedlines{8mm}\end{questions}\pointtable[v][questions]
            """#
        for (options, preamble, answerKey) in [("", "", false), ("answers", "", true), ("", #"\printanswers"#, true)] {
            let html = exam(source, options: options, preamble: preamble).body
            #expect(html.contains("data-exam-credit=\"1\">(a)</span>"))
            #expect(html.contains("data-exam-credit=\"2.5\">i.</span>"))
            #expect(html.contains("<td>1</td><td>3.5</td>"))
            #expect(
                html.contains("latex-exam-oneparchoices") && html.contains("latex-exam-box")
                    && html.contains("latex-exam-dots"))
            for word in ["First.", "Second.", "Cedar", "Maple", "Oak", "Green"] { #expect(html.contains(word)) }
            #expect(html.contains("Key edition.") == answerKey)
            #expect(html.contains("Practice edition.") != answerKey)
            #expect(html.contains("Correct entry") == answerKey)
            #expect(html.contains("SOLUTION-KEY") == answerKey)
            #expect(html.contains("☑") == answerKey)
            #expect(html.contains("latex-exam-correct") == answerKey)
            #expect(html.contains("A.</span> Cedar"))
            #expect(!html.contains("<td>Score</td>"))
        }
    }

    @Test("初頁と続頁の柱を変え、頁ごとの採点表は実ページの測定に渡す")
    func furniture() throws {
        let result = exam(
            #"\begin{questions}\question[4] Rail.\end{questions}\gradetable[v][pages]\pointtable[h][pages]"#,
            preamble:
                #"\firstpageheader{Start}{\numquestions}{}\runningheader{Continue}{}{\thepage}\cfoot[First]{Pts: \numpoints}"#
        )
        var numbers = try #require(result.latexClass?.pageNumbers)
        #expect(numbers.header == ["Start", "1", ""])
        #expect(numbers.footer == ["", "First", ""])
        numbers.advance()
        #expect(numbers.header == ["Continue", "", "2"])
        #expect(numbers.footer == ["", "Pts: 4", ""])
        #expect(result.body.contains(#"data-exam-pages="v" data-exam-grade="true""#))
        #expect(result.body.contains(#"data-exam-pages="h" data-exam-grade="false""#))
    }
}
