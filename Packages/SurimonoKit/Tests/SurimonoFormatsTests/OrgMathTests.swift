import SurimonoFormats
import Testing

struct OrgMathTests {
    private func body(_ org: String) -> String { OrgConverter.convert(org).body }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test("ドル記号と \\( \\) で囲んだ式は、強調に崩されずに行の中の数式になる")
    func inlineMath() {
        let html = body(#"式 $a*b + c*d$ と \(x_1 / y_1\) と *強調*"#)
        #expect(count("<span class=\"math math-inline\"><svg", in: html) == 2)
        #expect(html.contains("aria-label=\"a*b + c*d\""))
        #expect(html.contains("aria-label=\"x_1 / y_1\""))
        #expect(html.contains("<strong>強調</strong>"))
        #expect(!html.contains("<strong>b + c</strong>"))
    }

    @Test("和文に続けて書いた式も数式になる")
    func inlineMathNextToJapanese() {
        #expect(body("質量は$m$です。").contains("aria-label=\"m\""))
    }

    @Test("値段のドル記号・シェルの変数・コードと固定幅の行の中は数式にしない")
    func notMath() {
        #expect(!body("$5 と $10 です").contains("math"))
        #expect(!body("$HOME と $PATH を見る").contains("math"))
        #expect(body("=$x$= はコード").contains("<code>$x$</code>"))
        #expect(body(": $x$").contains("<pre>$x$</pre>"))
        #expect(!body("#+begin_src sh\necho $a $b\n#+end_src").contains("math"))
        #expect(!body("#+begin_example\n\\[ x \\]\n#+end_example").contains("math"))
    }

    @Test("段落がまるごと \\[ \\] か $$ の式なら、段落ではなく数式のブロックになる")
    func displayParagraph() {
        let bracket = body("前の文\n\n\\[\n  E = mc^2\n\\]\n\n後の文")
        #expect(bracket.contains("<div class=\"math-block\"><span class=\"math math-display\"><svg"))
        #expect(bracket.contains("aria-label=\"E = mc^2\""))
        #expect(bracket.contains("<p>前の文</p>"))
        #expect(bracket.contains("<p>後の文</p>"))
        #expect(!bracket.contains("<p><span class=\"math"))

        let dollars = body("$$ a^2 + b^2 = c^2 $$")
        #expect(dollars.contains("<div class=\"math-block\"><span class=\"math math-display\"><svg"))
    }

    @Test("文の途中の \\[ \\] は、その段落の中の別行の数式になる")
    func displayInsideParagraph() {
        let html = body(#"ここで \[ x = 1 \] とする。"#)
        #expect(html.contains("<p>ここで <span class=\"math math-display\"><svg"))
        #expect(html.contains("とする。</p>"))
    }

    @Test("行頭の equation 環境は番号の付いた数式のブロックになり、星付きには番号が付かない")
    func equationEnvironment() {
        let html = body(
            """
            \\begin{equation}
            x = 1
            \\end{equation}

            \\begin{equation*}
            y = 2
            \\end{equation*}

            \\begin{equation}
            z = 3
            \\end{equation}
            """)
        #expect(count("<div class=\"math-block", in: html) == 3)
        #expect(html.contains("<span class=\"eqno\">(1)</span>"))
        #expect(html.contains("<span class=\"eqno\">(2)</span>"))
        #expect(count("class=\"eqno\"", in: html) == 2)
        #expect(!html.contains("\\begin"))
        #expect(!html.contains("math-error"))
    }

    @Test("align 環境は行ごとに番号を振り、\\label は紙に出さない")
    func alignEnvironment() {
        let html = body(
            """
            \\begin{align}
            a &= b \\label{eq:first} \\\\
            c &= d
            \\end{align}
            """)
        #expect(count("<div class=\"math-block\">", in: html) == 1)
        #expect(!html.contains("math-error"))
        #expect(!html.contains("eq:first"))
        // Each number sits at the right margin on its row, outside the formula's drawing.
        #expect(count("<span class=\"latex-row-number\" style=\"top: ", in: html) == 2)
        #expect(html.contains("%\">(1)</span><span class=\"latex-row-number\""))
        #expect(html.contains("%\">(2)</span>"))
    }

    @Test("閉じていない環境と、数式でない環境は文字のまま残す")
    func notAnEnvironment() {
        #expect(body("\\begin{equation}\nx = 1").contains("\\begin{equation}"))
        #expect(!body("\\begin{equation}\nx = 1").contains("math"))
        #expect(body("\\begin{tabular}{ll}\na & b\n\\end{tabular}").contains("\\begin{tabular}"))
    }

    @Test("読めない式は原文を目印つきで残す")
    func unreadable() {
        #expect(body(#"式 $\frac{1$ です"#).contains("<code class=\"math-error\">$\\frac{1$</code>"))
    }

    @Test("#+LATEX_HEADER の \\newcommand と \\DeclareMathOperator は数式の中で使える")
    func headerMacros() {
        let html = body(
            """
            #+LATEX_HEADER: \\newcommand{\\R}{\\mathbb{R}}
            #+LATEX_HEADER: \\DeclareMathOperator{\\rank}{rank}
            #+LATEX_HEADER: \\usepackage{amsmath}

            $x \\in \\R$ と $\\rank A$
            """)
        #expect(count("<span class=\"math math-inline\"><svg", in: html) == 2)
        #expect(!html.contains("math-error"))
    }

    @Test("見出し・表・箇条書き・脚注の中の式も数式になる")
    func mathEverywhere() {
        let html = body(
            """
            * 見出しの $h$

            | 式    |
            |-------|
            | $t$   |

            - 項目の $l$

            本文[fn:1]

            [fn:1] 脚注の $f$
            """)
        for name in ["h", "t", "l", "f"] {
            #expect(html.contains("aria-label=\"\(name)\""))
        }
    }

    @Test("数式のある文書にだけ、使った数式の書体が本文の最後に入る")
    func fonts() {
        let math = body("$x$")
        #expect(math.contains("<style>\n@font-face { font-family: \"KaTeX_Math\""))
        #expect(math.hasSuffix("</style>\n"))
        #expect(!body("数式なし").contains("<style>"))
    }

    @Test("強調の中の式にある区切りの文字は、強調を閉じない")
    func emphasisAroundMath() {
        let html = body("*式 $a* b$ 続き*")
        #expect(html.hasPrefix("<p><strong>式 <span class=\"math math-inline\">"))
        #expect(html.contains("aria-label=\"a* b\""))
        #expect(html.contains("続き</strong>"))
    }

    @Test("コードの中の式の始まりは、コードの後ろの式や日付を隠さない")
    func codeBeforeMath() {
        let math = body(#"=\(x= と \(y\)"#)
        #expect(math.contains("<code>\\(x</code>"))
        #expect(math.contains("aria-label=\"y\""))

        let date = body(#"=\(= <2026-11-17 Tue> \)"#)
        #expect(date.contains("<code>\\(</code>"))
        #expect(date.contains("<time class=\"org-timestamp\">2026-11-17 Tue</time>"))
        #expect(!date.contains("math"))
    }

    @Test("強調の中のコードにある式の始まりは、強調の終わりを隠さない")
    func codeInsideEmphasis() {
        let html = body(#"*before =\(= after* tail \)"#)
        #expect(html.contains("<strong>before <code>\\(</code> after</strong> tail \\)"))
    }

    @Test("強調の先読みで閉じないと分かったコードの印は、その手前の閉じたコードを文字に戻さない")
    func lookaheadKeepsEarlierCode() {
        #expect(body("*a =ok= =b") == "<p>*a <code>ok</code> =b</p>\n")
        #expect(body("*a ~ok~ ~b") == "<p>*a <code>ok</code> ~b</p>\n")
    }

    @Test("閉じた環境は、後ろに閉じていない環境があっても数式になる")
    func closedBeforeUnclosed() {
        let html = body("\\begin{equation}\nx=1\n\\end{equation}\n\n\\begin{equation}\ny=2")
        #expect(html.contains("<span class=\"eqno\">(1)</span>"))
        #expect(html.contains("<p>\\begin{equation}\ny=2</p>"))
    }

    @Test("閉じる行が見出しにある環境は、見出しを飲み込まずに文字のまま残る")
    func headlineEndsEnvironment() {
        let html = body("\\begin{equation}\nx = 1\n* 見出し \\end{equation}")
        #expect(html.contains("<h1>見出し \\end{equation}</h1>"))
        #expect(!html.contains("math"))
    }

    @Test("閉じていない環境が何千行と並んでも、文字のまますぐに返る", .timeLimit(.minutes(1)))
    func unclosedEnvironments() {
        let text = Array(repeating: "\\begin{equation}", count: 20_000).joined(separator: "\n")
        #expect(!body(text).contains("class=\"math"))
    }

    @Test("閉じていない式の始まりが何千と並んでも、文字のまますぐに返る", .timeLimit(.minutes(1)))
    func unclosedOpeners() {
        for opener in ["\\[", "\\(", "$a ", "$$"] {
            let text = String(repeating: opener, count: 20_000)
            #expect(!body(text).contains("class=\"math"))
        }
    }

    @Test("脚注の番号と式の番号は、式があっても一度ずつしか進まない")
    func numbersAdvanceOnce() {
        let html = body(
            """
            本文[fn:a] と $x$

            \\begin{equation}
            y
            \\end{equation}

            [fn:a] 注
            """)
        #expect(html.contains("<span class=\"eqno\">(1)</span>"))
        #expect(html.contains("id=\"fnref-1\""))
        #expect(count("<li id=\"fn-", in: html) == 1)
    }
}
