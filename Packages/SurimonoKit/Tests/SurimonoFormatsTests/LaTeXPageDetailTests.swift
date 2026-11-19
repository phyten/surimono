import Foundation
import SurimonoFormats
import Testing

struct LaTeXPageDetailTests {
    @Test("細い塗り罫は実寸の箱に縮小描画し、ゼロ高の支柱は塗らない")
    func hairline() {
        let html = LaTeXConverter.convert(#"\rule{2mm}{.3pt}\rule{2mm}{0pt}\rule{2mm}{.5pt}"#).body
        #expect(html.ranges(of: "transform: scaleY(.1)").count == 1)
        #expect(
            html.contains("height: calc(0.3 * var(--tex-pt, 0.996264pt)); position: relative"))
    }

    @Test("内側の表で空の列間指定があれば左右の字下げを重ねない")
    func nestedEdges() {
        let html = LaTeXConverter.convert(
            #"\begin{tabular}{p{2cm}}\begin{tabular}[t]{@{}l@{}}A\\B\end{tabular}\end{tabular}"#
        ).body
        #expect(html.ranges(of: "padding-inline-start: 0; padding-inline-end: 0").count == 2)
        #expect(html.contains("width: calc(56.9055118 * var(--tex-pt, 0.996264pt))\"><table"))
    }

    @Test("上下に限界を置いた複合演算子でも本体の各字は正立し、添字は数式イタリックになる")
    func operatorWithLimits() {
        let html = LaTeXConverter.convert(#"\DeclareMathOperator*{\best}{arg\,min}\[\best_{x}^{y}\]"#).body
        for ch in "argmin" {
            let glyph = html.range(
                of: #"<text [^>]*font-family="KaTeX_Main"[^>]*font-style="normal"[^>]*>"# + String(ch) + "</text>",
                options: .regularExpression)
            #expect(glyph != nil)
        }
        #expect(html.range(of: #"<text [^>]*font-style="italic"[^>]*>x</text>"#, options: .regularExpression) != nil)
    }

    @Test("リンクは内部参照・引用・外部リンクの指定色を分け、隠し指定を優先する")
    func linkColors() {
        let preamble =
            #"\documentclass{article}\usepackage[colorlinks,linkcolor=blue,citecolor=black]{hyperref}\definecolor{web}{HTML}{AABBCC}\hypersetup{urlcolor=web}"#
        let body =
            #"\begin{document}\section{Title}\label{a}\ref{a}\cite{b}\url{https://example.test}\begin{thebibliography}{1}\bibitem{b}Book\end{thebibliography}\end{document}"#
        let visible = LaTeXConverter.convert(preamble + body).body
        #expect(visible.contains(##"a[href^="#"] { color: var(--latex-link-ink, #0000ff); }"##))
        #expect(visible.contains(".latex-cite a[href] { color: var(--latex-cite-ink, #000000); }"))
        #expect(visible.contains("a[href] { color: var(--latex-url-ink, #aabbcc);"))
        let hidden = LaTeXConverter.convert(preamble + #"\hypersetup{hidelinks}"# + body).body
        #expect(!hidden.contains("#aabbcc"))
        #expect(hidden.contains(#"href="https://example.test""#))
    }

    @Test("本文でグループ内だけ色を替えれば後続のリンクと先行のリンクには及ばない")
    func scopedInk() {
        let tex =
            #"\documentclass{article}\usepackage[colorlinks,urlcolor=red]{hyperref}\begin{document}\url{https://a.test}{\hypersetup{urlcolor=blue}\url{https://b.test}}\url{https://c.test}\end{document}"#
        let html = LaTeXConverter.convert(tex).body
        #expect(html.ranges(of: #"class="latex-link-colors""#).count == 1)
        #expect(html.contains("--latex-url-ink: #0000ff"))
        #expect(html.contains("color: var(--latex-url-ink, #ff0000)"))
        #expect(html.contains(#"</a></span><a class="latex-url" href="https://c.test""#))
    }

    @Test("章後のカウンター目印は段落を作らず、最初の見出し風マクロを本文の先頭に置く")
    func macroIndentation() {
        let html = LaTeXConverter.convert(
            #"\documentclass{report}\newcounter{row}\newcommand{\rowhead}{\refstepcounter{row}\par\textbf{Row }}\begin{document}\chapter{Start}\rowhead One\end{document}"#
        ).body
        #expect(html.contains("</h2>\n<p><span id=\"counter-row-1\"></span><strong>Row"))
        #expect(!html.contains("</span></p>"))
    }
}
