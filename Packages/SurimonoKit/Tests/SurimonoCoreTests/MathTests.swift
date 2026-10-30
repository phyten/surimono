import SurimonoCore
import Testing

struct MathRendererTests {
    @Test("数式は文字の大きさに合わせた SVG になり、基準線にそろい、テーマの文字色を使う")
    func svg() throws {
        let html = try #require(MathRenderer.html(#"\frac{1}{2}"#, display: false))
        #expect(html.hasPrefix("<span class=\"math math-inline\"><svg"))
        #expect(html.contains("em\" height=\""))
        #expect(html.contains("style=\"vertical-align: -"))
        #expect(html.contains("overflow: visible"))
        #expect(html.contains("fill=\"currentColor\""))
        #expect(!html.contains("rgba(0,0,0,1)"))
        #expect(html.contains("aria-label=\"\\frac{1}{2}\""))
        // The fraction's rule keeps its own size; only the root element is sized in em.
        #expect(html.components(separatedBy: "em\" height=").count == 2)
        #expect(html.contains("<rect "))
    }

    @Test("読めない数式は nil を返し、代わりに原文を目印つきで出せる")
    func unreadable() {
        #expect(MathRenderer.html(#"\frac{1"#, display: false) == nil)
        #expect(MathRenderer.fallback("$a<b$", display: false) == "<code class=\"math-error\">$a&lt;b$</code>")
    }

    @Test("使った KaTeX の書体だけを data URL の @font-face にする")
    func fontFaces() throws {
        let html = try #require(MathRenderer.html("x + 1", display: false))
        let css = MathRenderer.fontFaces(for: html)
        #expect(css.contains("font-family: \"KaTeX_Math\"; font-weight: normal; font-style: italic;"))
        #expect(css.contains("font-family: \"KaTeX_Main\"; font-weight: normal; font-style: normal;"))
        #expect(css.contains("src: url(\"data:font/ttf;base64,"))
        #expect(!css.contains("KaTeX_Size"))
        #expect(MathRenderer.fontFaces(for: "<p>数式なし</p>").isEmpty)
    }
}

struct MarkdownMathTests {
    private func body(_ markdown: String) -> String { MarkdownConverter.convert(markdown).body }

    @Test("ドル記号で囲んだ式は強調などに崩されずに数式になる")
    func inlineMath() {
        let html = body("式 $a_1 + b_1$ と *強調*")
        #expect(html.contains("<span class=\"math math-inline\"><svg"))
        #expect(html.contains("aria-label=\"a_1 + b_1\""))
        #expect(html.contains("<em>強調</em>"))
        #expect(!html.contains("<em>1 + b</em>"))
    }

    @Test("値段のドル記号・エスケープしたドル記号・コードの中は数式にしない")
    func notMath() {
        #expect(!body("$5 と $10 です").contains("math"))
        #expect(body("\\$x$ は文字").contains("$x$ は文字"))
        #expect(body("`$x$` はコード").contains("<code>$x$</code>"))
        #expect(!body("```\n$$\nx\n$$\n```").contains("math-block"))
    }

    @Test("行をまたぐ $$ の式は一つのブロックになり、すぐ後の文を巻き込まない")
    func displayBlock() {
        let html = body("前の段落\n\n$$\nE = mc^2\n$$\n続く文")
        #expect(html.contains("<div class=\"math-block\"><span class=\"math math-display\"><svg"))
        #expect(html.contains("<p>続く文</p>"))
        #expect(html.contains("<p>前の段落</p>"))
    }

    @Test("引用の中の式のブロックも引用の中に置く")
    func displayBlockInQuote() {
        let html = body("> $$\n> x^2\n> $$\n> 続き")
        #expect(html.hasPrefix("<blockquote><div class=\"math-block\">"))
        #expect(html.contains("<p>続き</p>\n</blockquote>"))
    }

    @Test("バックスラッシュの括弧と math のコードブロックも数式にする")
    func otherDelimiters() {
        #expect(body("文 \\( x^2 \\) 文").contains("<span class=\"math math-inline\">"))
        #expect(body("\\[ \\sum_{k=1}^n k \\]").contains("<div class=\"math-block\">"))
        #expect(body("文中の $$x$$ 表示").contains("<span class=\"math math-display\">"))
        #expect(
            body("```math\n\\int_0^1 x\\,dx\n```").contains(
                "<div class=\"math-block\"><span class=\"math math-display\">"))
    }

    @Test("読めない式は原文を目印つきで残す")
    func unreadableInMarkdown() {
        #expect(body("式 $\\frac{1$ です").contains("<code class=\"math-error\">$\\frac{1$</code>"))
    }

    @Test("見出しの式は表題に含めず、脚注の中の式も数式にする")
    func headingsAndFootnotes() {
        #expect(MarkdownConverter.convert("# 式 $x$ の話").title == "式  の話")
        #expect(body("本文[^1]\n\n[^1]: 注の $y$").contains("<li id=\"fn-1\"><p>注の <span class=\"math math-inline\">"))
    }

    @Test("数式があるときだけ、使った書体を本文の最後で読み込む")
    func fontsAtTheEnd() {
        let html = body("# 見出し\n\n$x$")
        #expect(html.hasPrefix("<h1"))
        #expect(html.hasSuffix("</style>\n"))
        #expect(html.contains("@font-face"))
        #expect(!body("数式なし").contains("<style>"))
    }
}

struct MarkdownMathBoundaryTests {
    private func body(_ markdown: String) -> String { MarkdownConverter.convert(markdown).body }

    @Test("式のブロックの続きの行の先頭の記号は式の一部として残す")
    func operatorsAtLineStartStay() {
        let html = body("$$\n- x\n+ y\n> 0\n$$")
        #expect(html.contains("aria-label=\"- x\n+ y\n&gt; 0\""))
    }

    @Test("引用の中で閉じていない式は、引用の外の見出しや本文を取り込まない")
    func unclosedBlockStaysInItsQuote() {
        let html = body("> $$\n> x\n\n# 見出し\n\n本文\n\n$$")
        #expect(html.contains("<h1 id=\"見出し\">見出し</h1>"))
        #expect(html.contains("<p>本文</p>"))
        #expect(!html.contains("math-block"))
    }

    @Test("リストの項目で閉じていない式は次の項目を取り込まず、項目の中の記号は式に残す")
    func listItemBoundary() {
        let unclosed = body("- $$\n  x\n- next\n  $$")
        #expect(unclosed.contains("next"))
        #expect(!unclosed.contains("math-block"))
        let closed = body("- 式:\n\n  $$\n  - x\n  $$\n- 次")
        #expect(closed.contains("aria-label=\"- x\""))
        #expect(closed.contains("<div class=\"math-block\">"))
        #expect(closed.contains("</div>\n</li>\n<li><p>次</p>"))
    }

    @Test(
        "リストと引用が入れ子になっていても、閉じた式のブロックを見つける",
        arguments: [
            "- > $$\n  > x\n  > $$", "> - $$\n>   x\n>   $$", "1. $$\n   x\n   $$", "-\t$$\n    x\n    $$",
            "-\t$$\n\tx\n\t$$", "- - $$\n\tx\n\t$$", "- - $$\n    x\n    $$",
        ])
    func nestedContainers(markdown: String) {
        #expect(MarkdownConverter.convert(markdown).body.contains("<div class=\"math-block\">"))
    }

    @Test("閉じていない式の探し方は区切りの種類ごとで、別の区切りの式は見つける")
    func searchesByDelimiter() {
        #expect(body("$$a\n\\[\nx\n\\]").contains("<div class=\"math-block\">"))
        #expect(body("\\[a\n$$\ny\n$$").contains("<div class=\"math-block\">"))
    }

    @Test("式の中のエスケープしたドル記号と、エスケープしたバックスラッシュのあとの式を読む")
    func escapesAroundDollars() {
        #expect(body("値段は $\\text{\\$5}$ です").contains("aria-label=\"\\text{\\$5}\""))
        #expect(body("\\\\$x$ の前").contains("<span class=\"math math-inline\">"))
    }

    @Test("私用領域の文字で書いた目印のような文字列は、そのまま残す")
    func tokenLikeTextStays() {
        #expect(body("a \u{E000}0\u{E001} b").contains("a \u{E000}0\u{E001} b"))
        #expect(body("$y$ と \u{E000}0\u{E001}").contains("と \u{E000}0\u{E001}"))
        #expect(body("$y$ と &#xE000;0&#xE001;").contains("と \u{E000}0\u{E001}"))
    }

    @Test("閉じていない $$ が続く文書も、同じ長さの普通の文書と同じくらいの時間で読む")
    func unclosedOpeningsAreScannedOnce() {
        func duration(_ line: String) -> Duration {
            let markdown = Array(repeating: line, count: 2_000).joined(separator: "\n")
            let start = ContinuousClock.now
            _ = MarkdownConverter.convert(markdown)
            return ContinuousClock.now - start
        }
        let plain = duration("aa")
        let unclosed = duration("$$a")
        // Searching from every opening to the end again would take thousands of times as many line visits.
        #expect(unclosed < plain * 2 + .milliseconds(500), "\(unclosed) vs \(plain)")
        // A search stops at a blank line, so a closed formula after it is still found.
        #expect(MarkdownConverter.convert("$$a\n\n$$\nx\n$$").body.contains("<div class=\"math-block\">"))
    }
}
