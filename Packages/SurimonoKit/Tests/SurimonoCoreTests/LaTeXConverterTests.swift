import Foundation
import SurimonoCore
import Testing

struct LaTeXConverterTests {
    private func body(_ latex: String) -> String { LaTeXConverter.convert(latex).body }
    private func document(_ body: String, class name: String = "article") -> String {
        "\\documentclass{\(name)}\n\\begin{document}\n\(body)\n\\end{document}\n"
    }

    @Test("前置きの表題・著者・日付を \\maketitle で出し、表題を文書の題名にする")
    func titleBlock() {
        let fragment = LaTeXConverter.convert(
            "\\documentclass{article}\n\\title{星見 \\& 図書室}\n\\author{甲 \\and 乙}\n\\date{2026年}\n"
                + "\\begin{document}\n\\maketitle\n本文\n\\end{document}")
        #expect(fragment.title == "星見 & 図書室")
        #expect(
            fragment.body.hasPrefix("<header class=\"latex-title-block\">\n<h1 class=\"latex-title\">星見 &amp; 図書室</h1>")
        )
        #expect(
            fragment.body.contains(
                "<span class=\"latex-author-name\">甲</span><span class=\"latex-author-name\">乙</span>"))
        #expect(fragment.body.contains("<p class=\"latex-date\">2026年</p>"))
        #expect(fragment.body.contains("<p>本文</p>"))
        #expect(!body("\\date{}\\title{T}\\maketitle").contains("latex-date"))
    }

    @Test("節に番号を振り、\\label と \\ref で後ろの節にもリンクする")
    func sectionsAndReferences() {
        let html = body(
            document(
                "\\section{前}\\label{a}\n\\ref{b}節へ\n\\section{後}\\label{b}\n\\subsection{細目}\n\\ref{a}と\\ref{none}"))
        #expect(html.contains("<h2 id=\"sec-1\"><span class=\"secnum\">1</span>前</h2>"))
        #expect(html.contains("<h3 id=\"sec-2-1\"><span class=\"secnum\">2.1</span>細目</h3>"))
        #expect(html.contains("<a href=\"#sec-2\">2</a>節へ"))
        #expect(html.contains("<a href=\"#sec-1\">1</a>と<span class=\"latex-missing\">??</span>"))
    }

    @Test("章のある文書クラスは章から番号を振り、付録は文字にし、星付きの節は番号なしで目次に入れない")
    func chaptersAppendixAndStars() {
        let html = body(
            document(
                "\\tableofcontents\n\\chapter{序}\n\\section{節}\n\\section*{番号なし}\n\\appendix\n\\chapter{補足}",
                class: "jsbook"))
        #expect(html.contains("<h2 id=\"sec-1\"><span class=\"secnum\">第1章</span>序</h2>"))
        #expect(html.contains("<h3 id=\"sec-1-1\"><span class=\"secnum\">1.1</span>節</h3>"))
        #expect(html.contains("<h3 id=\"sec-u3\">番号なし</h3>"))
        #expect(html.contains("<span class=\"secnum\">付録A</span>補足"))
        #expect(html.hasPrefix("<nav class=\"toc\">"))
        #expect(!html.components(separatedBy: "</nav>")[0].contains("番号なし"))
    }

    @Test("コメントを消し、改行を挟んだ日本語の間には空白を入れず、英語の間には入れる")
    func commentsAndLineBreaks() {
        #expect(body("日本語の%コメント\n文と\nつながる").contains("<p>日本語の文とつながる</p>"))
        #expect(body("English\nwords").contains("<p>English words</p>"))
        #expect(body("一段落\n\n二段落").contains("<p>一段落</p>\n<p>二段落</p>"))
        #expect(body("百\\%と\\$と\\#").contains("百%と$と#"))
    }

    @Test("ダッシュ・引用符・アクセント・空白の記号を文字にする")
    func typography() {
        #expect(body("1--2---3 ``q'' \\'e\\\"o\\c{c} a~b \\LaTeX{} \\ldots").contains("1–2—3 “q” éöç a&nbsp;b LaTeX …"))
    }

    @Test("書体のコマンドと、グループの終わりまで効く宣言と大きさ")
    func fonts() {
        let html = body("\\textbf{太} \\emph{強} {\\bfseries 宣言} 後 {\\large 大}")
        #expect(
            html.contains(
                "<strong>太</strong> <em>強</em> <strong>宣言</strong> 後 <span style=\"font-size: 1.2em\">大</span>"))
    }

    @Test("\\newcommand を引数と省略時の値つきで展開し、数式の中でも使える")
    func macros() {
        let html = body(
            "\\documentclass{article}\n\\newcommand{\\hi}[2][やあ]{#1、#2}\n\\newcommand{\\R}{\\mathbb{R}}\n"
                + "\\begin{document}\n\\hi{太郎} \\hi[おはよう]{花子} $x\\in\\R$\n\\end{document}")
        #expect(html.contains("やあ、太郎 おはよう、花子"))
        #expect(html.contains("<span class=\"math math-inline\"><svg"))
        #expect(html.contains("aria-label=\"x\\in\\R\""))
        #expect(!html.contains("math-error"))
    }

    @Test("数式は文中・別行・番号つきの環境を描き分け、\\eqref で番号を指す")
    func math() {
        let html = body(
            document(
                "文中 $a$ と \\(b\\)\n\\[c\\]\n\\begin{equation}E=mc^2\\label{eq:e}\\end{equation}\n"
                    + "\\begin{align*}x&=1\\\\y&=2\\end{align*}\n式\\eqref{eq:e}"))
        #expect(html.components(separatedBy: "math math-inline").count == 3)
        #expect(html.contains("<div class=\"math-block\"><span class=\"math math-display\">"))
        #expect(html.contains("<div class=\"math-block latex-equation\" id=\"eq-1\">"))
        #expect(html.contains("<span class=\"eqno\">(1)</span>"))
        #expect(html.contains("式<a href=\"#eq-1\">(1)</a>"))
        #expect(html.components(separatedBy: "eqno").count == 2)
        #expect(!html.contains("math-error"))
    }

    @Test("箇条書きは記号を、番号つきは入れ子で 1. と (a) を、enumitem の指定はその書式を使う")
    func lists() {
        let html = body(
            "\\begin{itemize}\\item 一\\item[*] 印\\end{itemize}"
                + "\\begin{enumerate}\\item 上\\begin{enumerate}\\item 下\\end{enumerate}\\end{enumerate}"
                + "\\begin{enumerate}[label=(\\roman*), start=3]\\item 三\\end{enumerate}"
                + "\\begin{enumerate}[(A)]\\item 甲\\end{enumerate}"
                + "\\begin{description}\\item[語] 説明\\end{description}")
        #expect(html.contains("<li>一</li>"))
        #expect(html.contains("<li class=\"latex-custom-label\"><span class=\"item-label\">*</span>印</li>"))
        #expect(html.contains("<p><span class=\"item-label\">1.</span>上</p>"))
        #expect(html.contains("<span class=\"item-label\">(a)</span>下"))
        #expect(html.contains("<span class=\"item-label\">(iii)</span>三"))
        #expect(html.contains("<span class=\"item-label\">(A)</span>甲"))
        #expect(html.contains("<dt>語</dt>\n<dd>説明</dd>"))
    }

    @Test("verbatim と lstlisting はそのまま出し、言語の指定があれば色を付ける")
    func code() {
        let html = body(
            "\\begin{verbatim}\n<a> & %b\n\\end{verbatim}\n\\begin{lstlisting}[language=Swift]\nlet x = 1\n\\end{lstlisting}\n\\verb|$x$|"
        )
        #expect(html.contains("<pre><code>&lt;a&gt; &amp; %b</code></pre>"))
        #expect(html.contains("<code class=\"language-swift hl\"><span class=\"hl-keyword\">let</span>"))
        #expect(html.contains("<code>$x$</code>"))
    }

    @Test("脚注は番号を振って末尾にまとめる")
    func footnotes() {
        let html = body("本文\\footnote{注の\\textbf{文}}と次")
        #expect(html.contains("本文<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>と次"))
        #expect(html.hasSuffix("<li id=\"fn-1\"><p>注の<strong>文</strong></p>\n</li>\n</ol>\n</section>\n"))
    }

    @Test("\\href と \\url は URL の % や # を保ち、エスケープを外す")
    func links() {
        let html = body("\\href{https://e.com/a\\#b}{リンク} \\url{https://e.com/%20x}")
        #expect(html.contains("<a href=\"https://e.com/a#b\">リンク</a>"))
        #expect(html.contains("<a class=\"latex-url\" href=\"https://e.com/%20x\">https://e.com/%20x</a>"))
    }

    @Test("xcolor の色名・定義した色・混ぜた色・HTML の色で文字に色を付ける")
    func colors() {
        let html = body(
            "\\documentclass{article}\\definecolor{ai}{HTML}{2B4C6F}\\begin{document}"
                + "\\textcolor{red}{赤}\\textcolor{ai}{藍}\\textcolor{blue!50}{淡}\\textcolor[HTML]{00FF00}{緑}"
                + "\\textcolor{nocolor}{無}\\end{document}")
        #expect(html.contains("<span style=\"color: #ff0000\">赤</span>"))
        #expect(html.contains("<span style=\"color: #2b4c6f\">藍</span>"))
        #expect(html.contains("<span style=\"color: #8080ff\">淡</span>"))
        #expect(html.contains("<span style=\"color: #00ff00\">緑</span>"))
        #expect(html.contains("無"))
    }

    @Test("図と表は別々に番号を振り、\\includegraphics の幅を CSS にする")
    func floats() {
        let html = body(
            document(
                "\\begin{figure}[h]\\centering\\includegraphics[width=0.5\\textwidth]{fig.png}\\caption{絵}\\label{f}\\end{figure}"
                    + "\\begin{table}\\caption{表題}\\label{t}\\end{table}\\ref{f}と\\ref{t}"))
        #expect(html.contains("<img class=\"latex-graphic\" src=\"fig.png\" alt=\"\" style=\"width: 50%\">"))
        #expect(
            html.contains(
                "<figcaption id=\"fig-1\"><span class=\"latex-caption-label\">Figure 1</span>: 絵</figcaption>"))
        #expect(
            html.contains(
                "<figcaption id=\"tab-1\"><span class=\"latex-caption-label\">Table 1</span>: 表題</figcaption>"))
        #expect(html.contains("<a href=\"#fig-1\">1</a>と<a href=\"#tab-1\">1</a>"))
    }

    @Test("拡張子のない画像は、文書の隣と \\graphicspath のフォルダから探す")
    func imageLookup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "latex-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "figures"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "figures/plot.pdf"))
        let html = LaTeXConverter.convert(
            "\\graphicspath{{figures/}}\\includegraphics{plot}\\includegraphics{missing}", directory: folder
        ).body
        #expect(html.contains("src=\"figures/plot.pdf\""))
        #expect(html.contains("src=\"missing\""))
    }

    @Test("表は列の揃えと縦線・横線、booktabs の見出し、\\multicolumn と \\multirow を表にする")
    func tables() {
        let html = body(
            "\\begin{tabular}{|l|c|}\\hline 甲 & 乙 \\\\ \\hline 丙 & 丁 \\\\ \\hline\\end{tabular}"
                + "\\begin{tabular}{lr}\\toprule 名 & 数 \\\\ \\midrule \\multicolumn{2}{c}{合計} \\\\ \\multirow{2}{*}{縦} & 1 \\\\ & 2 \\\\ \\bottomrule\\end{tabular}"
        )
        #expect(
            html.contains(
                "<td style=\"text-align: left; border-left: 0.5pt solid currentColor; border-right: 0.5pt solid currentColor; border-top: 0.5pt solid currentColor\">甲</td>"
            ))
        #expect(html.contains("border-bottom: 0.5pt solid currentColor\">丁</td>"))
        #expect(html.contains("<th style=\"text-align: left; border-top: 1pt solid currentColor\">名</th>"))
        #expect(html.contains("colspan=\"2\">合計</td>"))
        #expect(html.contains("rowspan=\"2\">縦</td>"))
        #expect(html.contains("<tr><td style=\"text-align: right; border-bottom: 1pt solid currentColor\">2</td></tr>"))
    }

    @Test("TikZ の図と \\input は、描けない・読まないことを枠で示す")
    func unsupported() {
        let html = body(document("\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}\\input{chapter1}"))
        #expect(html.contains("<div class=\"latex-unsupported\">TikZ picture (Surimono cannot draw it)</div>"))
        #expect(html.contains("<div class=\"latex-unsupported\">chapter1 is not included</div>"))
        #expect(
            body(document("\\begin{tikzpicture}\\end{tikzpicture}", class: "jsarticle")).contains("Surimono では描けません"))
    }

    @Test("知らないコマンドは文字を残し、設定だけのコマンドは引数ごと消す")
    func unknownCommands() {
        let html = body("\\foo{残る}\\setlength{\\parindent}{0pt}\\usepackage[x]{y}と\\relax 次")
        #expect(html.contains("<p>残ると次</p>"))
    }

    @Test("\\begin{document} のない断片も本文として読む")
    func fragment() {
        #expect(
            LaTeXConverter.convert("\\section{見出し}\n本文").body.hasPrefix(
                "<h2 id=\"sec-1\"><span class=\"secnum\">1</span>見出し</h2>"))
    }
}

struct LaTeXConverterBoundaryTests {
    private func body(_ latex: String) -> String { LaTeXConverter.convert(latex).body }

    @Test("負の引数の数・列の繰り返し・極端な開始番号や列の数でも落ちずに読む")
    func invalidNumbers() {
        #expect(body("\\newcommand{\\x}[-1]{a}\\x 残る").contains("残る"))
        #expect(body("\\begin{tabular}{*{-1}{c}}x\\end{tabular}").contains("x"))
        #expect(body("\\begin{enumerate}[start=-9223372036854775808]\\item 項\\end{enumerate}").contains("項"))
        #expect(body("\\begin{tabular}{c}\\multicolumn{99999999999}{c}{広}\\end{tabular}").contains("colspan=\"100\""))
    }

    @Test("ファイルの終わりのコメントで終わる環境でも落ちない")
    func commentAtTheEnd() {
        _ = body("\\begin{tabular}%")
        _ = body("\\begin{minipage}%")
        _ = body("文%")
    }

    @Test("NaN の色は使わず、文字だけを出す")
    func notANumberColor() {
        let html = body("\\textcolor[rgb]{nan,0,0}{文字}\\textcolor{red!nan}{二}")
        #expect(html.contains("文字二"))
        #expect(!html.contains("color:"))
    }

    @Test("引数を倍にし続けるマクロも、決まった大きさで展開をやめる")
    func doublingMacro() {
        let html = body("\\def\\a#1{\\a{#1#1}}\\a{x}後")
        #expect(html.count < 3_000_000)
        #expect(html.contains("後"))
    }

    @Test("引数の中の #1 はもう一度置き換えず、展開の大きさの見積もりをすり抜けない")
    func argumentsAreNotSubstitutedAgain() {
        let long = String(repeating: "a", count: 10_000)
        let markers = String(repeating: "#1", count: 1_000)
        let html = body("\\newcommand{\\x}[2]{#2}\\x{\(long)}{\(markers)}後")
        #expect(html.count < 50_000)
        #expect(html.contains("後"))
    }

    @Test("同じ引数を何度も使う本体は、大きくなりすぎる前に展開をやめる", .timeLimit(.minutes(1)))
    func manyUsesOfOneArgument() {
        let template = String(repeating: "#1", count: 10_000)
        let argument = String(repeating: "A", count: 10_000)
        let html = body("\\newcommand{\\x}[1]{\(template)}\\x{\(argument)}後")
        #expect(html.count < 200_000)
        #expect(html.contains("後"))
    }

    @Test("入れ子の列の繰り返しも、決まった列の数で読むのをやめる", .timeLimit(.minutes(1)))
    func nestedColumnRepeats() {
        let html = body("\\begin{tabular}{*{100}{*{100}{*{100}{*{100}{c}}}}}x\\end{tabular}")
        #expect(html.contains("x"))
    }

    @Test("コメントやコードの中の \\end{document} と \\chapter は文書の区切りや章にしない")
    func structureInCommentsAndCode() {
        let html = body(
            "\\documentclass{article}\\begin{document}\n前\n% \\end{document}\n% \\chapter{章}\n\\section{節}\n後\n\\end{document}"
        )
        #expect(html.contains("後"))
        #expect(html.contains("<span class=\"secnum\">1</span>節"))
        #expect(body("\\begin{document}\\verb|\\end{document}| 続く\\end{document}").contains("続く"))
    }

    @Test("\\verb の中の \\end{…} と \\item は環境の終わりや項目の区切りにしない")
    func verbatimInsideStructure() {
        let quote = body("\\begin{quote}\\verb|\\end{quote}|後\\end{quote}")
        #expect(quote.contains("<blockquote>\n<p><code>\\end{quote}</code>後</p>\n</blockquote>"))
        let list = body("\\begin{itemize}\\item \\verb|\\item|後\\end{itemize}")
        #expect(list.contains("<li><code>\\item</code>後</li>"))
        #expect(list.components(separatedBy: "<li>").count == 2)
    }

    @Test("脚注の中の \\ref も番号にする")
    func referenceInFootnote() {
        let html = body("\\section{節}\\label{s}本文\\footnote{第\\ref{s}節}")
        #expect(html.contains("<li id=\"fn-1\"><p>第<a href=\"#sec-1\">1</a>節</p>"))
        #expect(!html.contains("\u{E000}"))
    }

    @Test("align は行ごとに番号を振り、\\notag の行は飛ばし、ラベルはその行の番号を指す")
    func alignRowNumbers() {
        let html = body(
            "\\begin{align}a&=1\\label{a}\\\\b&=2\\notag\\\\c&=3\\label{c}\\end{align}\\eqref{a}と\\eqref{c}")
        #expect(
            html.contains(
                "<div class=\"math-block\"><span id=\"eq-1\"></span><span id=\"eq-2\"></span><span class=\"math math-display\">"
            ))
        #expect(html.contains("<a href=\"#eq-1\">(1)</a>と<a href=\"#eq-2\">(2)</a>"))
        #expect(!html.contains("math-error"))
    }

    @Test("align の中の行列の改行は、外側の式番号として数えない")
    func matrixRowsInsideAlign() {
        let html = body(
            "\\begin{align}A&=\\begin{pmatrix}1\\\\2\\end{pmatrix}\\label{a}\\\\b&=2\\label{b}\\end{align}\\eqref{a}と\\eqref{b}"
        )
        #expect(html.contains("<span id=\"eq-1\"></span><span id=\"eq-2\"></span><span class=\"math"))
        #expect(!html.contains("eq-3"))
        #expect(html.contains("<a href=\"#eq-1\">(1)</a>と<a href=\"#eq-2\">(2)</a>"))
    }

    @Test("\\tag を付けた式のラベルは、そのタグを指す")
    func labelsOfTaggedFormulas() {
        let html = body(
            "\\begin{equation}E=mc^2\\tag{A}\\label{e}\\end{equation}"
                + "\\begin{align}a&=1\\tag{B}\\label{f}\\\\b&=2\\label{g}\\end{align}"
                + "\\eqref{e}, \\ref{f}, \\eqref{g}")
        #expect(html.contains("<div class=\"math-block\" id=\"eq-t1\">"))
        #expect(html.contains("<a href=\"#eq-t1\">(A)</a>, <a href=\"#eq-t2\">B</a>, <a href=\"#eq-1\">(1)</a>"))
    }

    @Test("表題の中の \\maketitle は表題をもう一度作らない", .timeLimit(.minutes(1)))
    func titleThatMakesTheTitle() {
        let html = body("\\title{題\\maketitle\\maketitle}\\maketitle 後")
        #expect(html.components(separatedBy: "<header class=\"latex-title-block\">").count == 2)
        #expect(html.contains("後"))
    }

    @Test("深く入れ子になった波括弧は、決まった深さから先を文字のまま出す", .timeLimit(.minutes(1)))
    func deeplyNestedGroups() {
        let html = body(String(repeating: "{", count: 100_000) + "x" + String(repeating: "}", count: 100_000) + "後")
        #expect(html.contains("x"))
        #expect(html.contains("後"))
    }

    @Test("長い \\tag への参照は、何度書いても決まった長さの番号を出す", .timeLimit(.minutes(1)))
    func referencesToLongTags() {
        let tag = String(repeating: "T", count: 10_000)
        let html = body(
            "\\begin{equation}x\\tag{\(tag)}\\label{e}\\end{equation}" + String(repeating: "\\ref{e}", count: 10_000))
        #expect(html.utf8.count < 5_000_000)
        #expect(html.contains("<a href=\"#eq-t1\">\(String(repeating: "T", count: 100))…</a>"))
    }

    @Test("拡張子のある画像も \\graphicspath のフォルダから探す")
    func graphicsPathWithExtension() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "latex-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "figures"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "figures/plot.png"))
        let html = LaTeXConverter.convert("\\graphicspath{{figures/}}\\includegraphics{plot.png}", directory: folder)
            .body
        #expect(html.contains("src=\"figures/plot.png\""))
    }
}
