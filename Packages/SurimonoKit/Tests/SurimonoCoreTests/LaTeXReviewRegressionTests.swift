import Foundation
import SurimonoCore
import Testing

struct LaTeXReviewRegressionTests {
    private func body(_ source: String) -> String { LaTeXConverter.convert(source).body }

    @Test("見出しの題の中のラベルはその見出しの番号とリンク先を指す")
    func labelsInsideHeadings() {
        let html = body(
            #"""
            \documentclass{book}\begin{document}
            \part{部\label{p}}\chapter{章\label{c}}
            \section{前}\section{導入\label{s}}\subsection{細目\label{ss}}
            \ref{p}/\ref{c}/\ref{s}/\ref{ss}
            \end{document}
            """#)
        #expect(html.contains("<a href=\"#part-1\">I</a>/<a href=\"#sec-1\">1</a>"))
        #expect(html.contains("<a href=\"#sec-1-2\">1.2</a>/<a href=\"#sec-1-2-1\">1.2.1</a>"))
    }

    @Test("図と表の題の中のラベルはその図と表の独立した番号を指す")
    func labelsInsideCaptions() {
        let html = body(
            #"""
            \section{前}\section{後}
            \begin{figure}\caption{図\label{f1}}\end{figure}
            \begin{table}\caption{表\label{t1}}\end{table}
            \begin{figure}\caption[短い題]{次の図\label{f2}}\end{figure}
            \ref{f1}/\ref{t1}/\ref{f2}
            """#)
        #expect(html.contains("<a href=\"#fig-1\">1</a>/<a href=\"#tab-1\">1</a>/<a href=\"#fig-2\">2</a>"))
    }

    @Test("定理の補足題の中のラベルは現在の定理の番号を指す")
    func labelsInsideTheoremNotes() {
        let html = body(
            #"""
            \newtheorem{thm}{定理}[section]\section{前}\section{後}
            \begin{thm}[最初\label{t1}]本文\end{thm}
            \begin{thm}[次\label{t2}]本文\end{thm}
            \ref{t1}/\ref{t2}
            """#)
        #expect(html.contains("<a href=\"#thm-1\">2.1</a>/<a href=\"#thm-2\">2.2</a>"))
    }

    @Test(
        "enumitem の設定キーを番号の書式として印刷しない",
        arguments: [
            "noitemsep", "nosep", "nolistsep", "leftmargin=*", "itemsep=0pt", "topsep=0pt", "parsep=0pt",
            "partopsep=0pt", "labelsep=1em", "labelwidth=2em", "itemindent=0pt", "align=left", "wide",
            "resume", "series", "ref", "font", "before", "after", "leftmargin", "itemsep", "start",
            "topsep", "parsep", "partopsep", "labelsep", "labelwidth", "itemindent", "align",
            "noitemsep,nosep", "a1", "ii", "plain", "label=literal",
        ])
    func enumerateSettingsKeepDefaultNumbers(options: String) {
        let html = body("\\begin{enumerate}[\(options)]\\item 甲\\item 乙\\end{enumerate}")
        #expect(html.contains("<span class=\"item-label\">1.</span>甲"))
        #expect(html.contains("<span class=\"item-label\">2.</span>乙"))
    }

    @Test(
        "enumerate の短い書式は番号文字一つと前後の記号だけを読む",
        arguments: [("a)", "a)"), ("(i)", "(i)"), ("1.", "1."), ("A.", "A."), ("{[I]}", "[I]")])
    func shortEnumerateLabels(example: (String, String)) {
        let html = body("\\begin{enumerate}[\(example.0)]\\item 甲\\end{enumerate}")
        #expect(html.contains("<span class=\"item-label\">\(example.1)</span>甲"))
    }

    @Test("enumitem の label と start は余白の指定と一緒でも読む")
    func explicitEnumerateLabels() {
        let html = body("\\begin{enumerate}[noitemsep,label=(\\roman*),start=3,leftmargin=*]\\item 甲\\end{enumerate}")
        #expect(html.contains("<span class=\"item-label\">(iii)</span>甲"))
    }

    @Test(
        "リスト中の URL のパーセントとエスケープしたパーセントを保ち次の項目を分ける",
        arguments: ["url", "href", "path", "nolinkurl"], ["%20", "\\%20"])
    func percentInListURLs(command: String, percent: String) {
        let link = "\\\(command){https://example.com/a\(percent)b}" + (command == "href" ? "{リンク}" : "")
        let html = body("\\begin{itemize}\\item \(link)\n\\item 次\\end{itemize}後")
        #expect(html.contains("https://example.com/a%20b"))
        #expect(html.contains("</li>\n<li>次</li>\n</ul>\n<p>後</p>"))
    }

    @Test("グループ内の URL はコメントを始めず href の表示名と通常の本文ではコメントを消す")
    func groupedURLAndComments() {
        let html = body(
            #"""
            \begin{itemize}\item \textbf{\url{https://example.com/a%20b}}
            \item \href{https://example.com/a%20b}{表% コメント
            示}\item 百\% % コメント
            \item 次\end{itemize}
            """#)
        #expect(html.contains("<strong><a class=\"latex-url\" href=\"https://example.com/a%20b\">"))
        #expect(html.contains("<a href=\"https://example.com/a%20b\">表示</a>"))
        #expect(html.contains("<li>百%</li>\n<li>次</li>"))
        #expect(!html.contains("コメント"))
    }

    @Test("幅を持つ表環境は幅と位置を捨てて列の揃えを読む", arguments: ["tabular*", "tabularx", "tabulary"])
    func tablesWithWidth(environment: String) {
        let html = body("\\begin{\(environment)}{\\textwidth}[t]{lcr}左 & 中 & 右\\end{\(environment)}")
        #expect(
            html == "<table class=\"latex-tabular\"><tbody>\n"
                + "<tr><td style=\"text-align: left\">左</td><td style=\"text-align: center\">中</td>"
                + "<td style=\"text-align: right\">右</td></tr>\n</tbody></table>\n")
    }

    @Test("回り込み図表は行数と位置とはみ出しと幅を本文に出さない")
    func wrappedFloats() {
        let html = body(
            #"""
            \begin{wrapfigure}{r}{0.4\textwidth}図の本文\caption{図題\label{f}}\end{wrapfigure}
            \begin{wraptable}[8]{L}[1em]{0.5\textwidth}表の本文\caption{表題\label{t}}\end{wraptable}
            \ref{f}/\ref{t}
            """#)
        #expect(html.contains("<figure class=\"latex-figure\">\n<p>図の本文</p>"))
        #expect(html.contains("<figure class=\"latex-table\">\n<p>表の本文</p>"))
        #expect(html.contains("<a href=\"#fig-1\">1</a>/<a href=\"#tab-1\">1</a>"))
        #expect(!html.contains("0.4"))
        #expect(!html.contains("1em"))
    }

    @Test("longtable の題は表として数え最初の見出しだけを残して本文と最後の脚注を並べる")
    func longtableCaptionAndSections() {
        let html = body(
            #"""
            \documentclass{jsarticle}\begin{document}
            \begin{table}\caption{前の表}\end{table}
            \begin{longtable}[c]{lr}
            \caption{長い表\label{lt}}\\
            名前 & 数\\\endfirsthead
            繰り返す見出し & 数\\\endhead
            途中の脚注 & 続く\\\endfoot
            最後の脚注 & 終わり\\\endlastfoot
            甲 & 1\\乙 & 2\\
            \end{longtable}
            \begin{figure}\caption{図}\end{figure}\ref{lt}
            \end{document}
            """#)
        #expect(
            html.contains("<figcaption id=\"tab-2\"><span class=\"latex-caption-label\">表 2</span>　長い表</figcaption>"))
        #expect(html.contains("<th style=\"text-align: left\">名前</th><th style=\"text-align: right\">数</th>"))
        #expect(html.contains("<td style=\"text-align: left\">甲</td><td style=\"text-align: right\">1</td>"))
        #expect(html.contains("<td style=\"text-align: left\">最後の脚注</td>"))
        #expect(!html.contains("繰り返す見出し"))
        #expect(!html.contains("途中の脚注"))
        #expect(html.components(separatedBy: "<tr>").count == 5)
        #expect(html.contains("<a href=\"#tab-2\">2</a>"))
        #expect(html.contains("<span class=\"latex-caption-label\">図 1</span>"))
    }

    @Test("longtable は endhead だけでも先頭を見出しにし境界だけの空行を出さない")
    func longtableSingleHead() {
        let html = body("\\begin{longtable}{l}名前\\\\\\endhead\\endfoot\\endlastfoot 甲\\\\\\end{longtable}")
        #expect(html.contains("<th style=\"text-align: left\">名前</th>"))
        #expect(html.contains("<td style=\"text-align: left\">甲</td>"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
    }

    @Test("節の下の番号付き見出しと定理の見出し名の中のラベルも現在の番号を指す")
    func labelsInsideDeeperHeadingsAndTheoremTitle() {
        let html = body(
            #"""
            \section{節}\subsection{小節}\subsubsection{細節\label{deep}}
            \newtheorem{thm}{定理\label{title}}\begin{thm}本文\end{thm}
            \ref{deep}/\ref{title}
            """#)
        #expect(html.contains("<a href=\"#sec-1-1-1\">1.1.1</a>/<a href=\"#thm-1\">1</a>"))
    }

    @Test("URL 内のエスケープした波括弧と項目や環境の文字は構造を変えない")
    func structuralCharactersInsideURL() {
        let html = body(
            #"""
            \begin{itemize}\item \url {https://example.com/a%20\}b/\item/\end{itemize}}
            \item 次\end{itemize}後
            """#)
        #expect(html.contains("https://example.com/a%20}b/item/end{itemize}"))
        #expect(html.contains("</li>\n<li>次</li>\n</ul>\n<p>後</p>"))
    }

    @Test(
        "コード環境のパーセントや項目名はそのまま保って次の項目を分ける",
        arguments: ["verbatim", "lstlisting", "minted"])
    func codeEnvironmentsRemainOpaque(environment: String) {
        let language = environment == "minted" ? "{text}" : ""
        let html = body(
            "\\begin{itemize}\\item \\begin{\(environment)}\(language)\n"
                + "% \\item \\end{itemize}\n\\end{\(environment)}\n\\item 次\\end{itemize}")
        #expect(html.contains("% \\item \\end{itemize}"))
        #expect(html.contains("<li>次</li>"))
        #expect(html.components(separatedBy: "<li>").count == 3)
    }

    @Test("longtable の境界は行末にも書けてコードやコメント中の同名コマンドでは区切らない")
    func longtableBoundariesAtRowEnds() {
        let html = body(
            #"""
            \begin{longtable}{l}
            名前\endhead
            % \endfirsthead
            \verb|\endhead|\\甲\\
            \end{longtable}
            """#)
        #expect(html.contains("<th style=\"text-align: left\">名前</th>"))
        #expect(html.contains("<td style=\"text-align: left\"><code>\\endhead</code></td>"))
        #expect(html.contains("<td style=\"text-align: left\">甲</td>"))
        #expect(html.components(separatedBy: "<tr>").count == 4)
    }

    @Test("longtable の最後の脚注が罫線だけでも本文の最終行に罫線を残す")
    func longtableFooterRule() {
        let html = body(
            #"""
            \begin{longtable}{l}
            名前\\\endhead
            \bottomrule\endlastfoot
            甲\\
            \end{longtable}
            """#)
        #expect(html.contains("<td style=\"text-align: left; border-bottom: 1pt solid currentColor\">甲</td>"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
    }
}
