import Foundation
import SurimonoFormats
import Testing

struct LaTeXBlockDetailTests {
    @Test("枠と背景は中央揃えの段落箱と minipage の幅で内容を囲む")
    func framedBlocks() {
        let result = LaTeXConverter.convert(
            #"""
            \definecolor{ink}{HTML}{000000}
            \fbox{\parbox{.5\linewidth}{\centering 見本\par 二行目}}
            \colorbox{ink!6}{\begin{minipage}{3cm}灰色\end{minipage}}
            \colorbox{blue!70!black}{\[a=b\]}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(
            result.body.contains(#"<div class="latex-minipage latex-fbox" style="width: 50%; vertical-align: middle">"#)
        )
        #expect(result.body.contains(#"<p style="text-align: center; text-indent: 0">見本</p>"#))
        #expect(result.body.contains(#"<p style="text-align: center; text-indent: 0">二行目</p>"#))
        #expect(result.body.contains(#"<div class="latex-minipage latex-colorbox" style="background: #f0f0f0;"#))
        #expect(
            result.body.contains(#"<div class="latex-colorbox" style="background: #0000b3; "><div class="math-block">"#)
        )
    }

    @Test("タイプライター体のダッシュと引用符は直接指定・宣言・独自コマンドで原文を保つ")
    func typewriterLigatures() {
        let html = LaTeXConverter.convert(
            #"""
            \newcommand{\flag}[1]{\texttt{#1}}
            \texttt{--one --- ``two''} {\ttfamily --three --- `four'} \flag{--five} --- ``six''
            """#
        ).body
        #expect(html.contains("<code>--one --- ``two&#39;&#39;</code>"))
        #expect(html.contains("<code>--three --- `four&#39;</code>"))
        #expect(html.contains("<code>--five</code> — “six”"))
    }

    @Test("グループ中の段落を分け、各段落の大きさを維持してグループの後で戻す")
    func groupedParagraphs() {
        let html = LaTeXConverter.convert(#"{\small 一段目\par 二段目\par}通常"#).body
        #expect(html.contains("<p><span style=\"font-size: 0.9em\">一段目</span></p>\n"))
        #expect(html.contains("<p><span style=\"font-size: 0.9em\">二段目</span></p>\n<p>通常</p>"))
    }

    @Test("表紙環境を独立したブロックにし可変の空きは印刷しない")
    func titlePage() {
        let result = LaTeXConverter.convert(#"\begin{titlepage}\vspace*{\fill}草稿\vfill\end{titlepage}本文"#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("<div class=\"latex-titlepage\">\n<p>草稿</p>\n</div>"))
        #expect(!result.body.contains("latex-vspace"))
    }

    @Test("コード一覧の題・開始行番号・指定した背景色を別々に保持する")
    func listingCaptionNumbersAndFill() {
        let result = LaTeXConverter.convert(
            #"""
            \begin{lstlisting}[numbers=left,firstnumber=4,backgroundcolor=\color{yellow!50},caption={出力例}]
            first
            next
            \end{lstlisting}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("</span>: 出力例</figcaption>"))
        #expect(result.body.contains(#"--latex-listing-background: #ffff80"#))
        #expect(result.body.contains(#"data-no="4"><span class="code-src">first</span>"#))
        #expect(result.body.contains(#"data-no="5"><span class="code-src">next</span>"#))
    }

    @Test("星付きの演算子宣言は正立の語を刷り細い空白の幅を保つ")
    func operatorSpacing() throws {
        func firstM(in name: String) throws -> Double {
            let html = LaTeXConverter.convert("\\DeclareMathOperator*{\\myop}{\(name)}\\[\\myop\\]").body
            let glyph = try #require(html.range(of: #"<text x="[^"]+"[^>]*>m</text>"#, options: .regularExpression))
            let tag = html[glyph]
            #expect(tag.contains(#"font-family="KaTeX_Main""#))
            #expect(tag.contains(#"font-style="normal""#))
            return try #require(tag.split(separator: "\"").dropFirst().first.flatMap { Double($0) })
        }
        let difference = try firstM(in: #"arg\,min"#) - firstM(in: "argmin")
        // The SVG coordinates use a 10-unit em. A TeX thin space is three math units (1/6 em).
        #expect(abs(difference - 10.0 / 6) < 0.001)
    }

    @Test("別行の用語・中央揃えの結合セル・詩の連を印刷用に保つ")
    func descriptionMultirowAndVerse() {
        let result = LaTeXConverter.convert(
            #"""
            \begin{description}[style=nextline]\item[用途]備考\end{description}
            \begin{tabular}{ll}\multirow{2}{*}{中間}&上\\&下\\\end{tabular}
            \begin{verse}一行目\\二行目\par 次の連\end{verse}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains(#"class="latex-description latex-nextline""#))
        #expect(result.body.contains(#"vertical-align: middle" rowspan="2">中間</td>"#))
        #expect(result.body.contains("<blockquote class=\"latex-verse\">\n<p>一行目<br>二行目</p>\n<p>次の連</p>"))
    }

    @Test("URL はスキームを保ち指定の区切り記号の後だけに改行候補を置く")
    func urlBreaks() {
        let html = LaTeXConverter.convert(#"\url{https://demo.example/A_B-C?D=E&F=G}"#).body
        let runs = ["https://demo.", "example/", "A_B-", "C?", "D=", "E&amp;", "F=", "G"]
        #expect(html.contains(runs.map { "<span>\($0)</span>" }.joined(separator: "<wbr>")))
    }
}
