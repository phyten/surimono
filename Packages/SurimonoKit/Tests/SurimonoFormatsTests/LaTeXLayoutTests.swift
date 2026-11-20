import Foundation
import SurimonoFormats
import Testing

struct LaTeXLayoutTests {
    @Test("minipage と parbox は同じ行に並び、hfill の間隔と各箱の幅・縦位置を保つ")
    func adjacentBoxes() {
        let html = LaTeXConverter.convert(
            #"前\begin{minipage}[t]{.45\textwidth}左\end{minipage}\hfill\parbox[b][3cm][c]{2cm}{右}後"#
        ).body
        #expect(html.contains("<p>前</p>\n<div class=\"latex-box-row latex-box-fill\">"))
        #expect(html.contains("width: 45%; vertical-align: top\"><p>左</p>\n</div> <div"))
        #expect(
            html.contains(
                "width: var(--latex-measured-width, calc(56.9055118 * var(--tex-pt, 0.996264pt))); vertical-align: bottom\"><p>右</p>\n</div></div>\n<p class=\"latex-noindent\">後</p>"
            ))
    }

    @Test("物理単位を用紙の本文幅に対する割合に変換し、入れ子では外側の箱を基準にする")
    func physicalBoxWidth() {
        let html = LaTeXConverter.convert(
            #"\begin{minipage}{.5\linewidth}\parbox{2.54cm}{Inside}\end{minipage}\parbox{1in}{Outside}"#,
            textWidthPoints: 360
        ).body
        #expect(html.contains("width: 50%;"))
        for fallback in ["40%", "20%"] {
            #expect(html.contains("--latex-box-points: 72; width: var(--latex-measured-width, \(fallback));"))
        }
    }

    @Test("子図は親の題が後でも同じ図番号を参照し、星付きの題で図番号を進めない")
    func subfigures() {
        let result = LaTeXConverter.convert(
            #"""
            \begin{figure}\caption{one}\end{figure}
            \begin{figure}
            \begin{subfigure}[b]{.3\linewidth}A\caption{first\label{a}}\end{subfigure}\hfill
            \subfloat[second]{B\label{b}}\hfill\subcaptionbox{third\label{c}}[.3\linewidth]{C}
            \subcaption{fourth}\label{d}
            \caption*{plain}\caption{Main}\label{all}
            \end{figure}
            \ref{a}/\ref{b}/\ref{c}/\ref{d}/\ref{all}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("(a)</span> first"))
        #expect(result.body.contains("(b)</span> second"))
        #expect(result.body.contains("<figcaption>plain</figcaption>"))
        for number in ["2a", "2b", "2c", "2d", "2"] {
            #expect(result.body.contains("<a class=\"latex-number-ref\" href=\"#fig-\(number)\">\(number)</a>"))
        }
    }

    @Test("multicols は段数と高さを印刷せず、前置きと本文を元の順で段組みに渡す")
    func columnSegment() {
        let result = LaTeXConverter.convert(#"\begin{multicols}{2}[Heading][6cm]本文\end{multicols}"#)
        #expect(result.body.contains("<div data-latex-wide><p>Heading</p>"))
        #expect(result.body.contains("data-latex-balance=\"true\"><p>本文</p>"))
        #expect(!result.body.contains("6cm"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test(
        "長い表は見出しを thead に入れ、継続と最後の脚を保持し、列指定・部分罫・色・セル内改行を反映する",
        arguments: ["longtable", "xltabular", "supertabular"])
    func longTables(name: String) {
        let width = name == "xltabular" ? #"[c]{\textwidth}"# : ""
        let result = LaTeXConverter.convert(
            "\\begin{\(name)}" + width
                + #"""
                {>{\bfseries\raggedleft}p{2cm}X<{\centering}m{1cm}b{1cm}}
                head&two&three&four\\\endhead
                dropped\\\endfoot
                last dropped\\\endlastfoot
                \rowcolor{yellow}\makecell{A\\B}&Q\cellcolor[HTML]{ff00cc}&R&S\\
                \cmidrule(lr){2-3}\cline{4-4}A&B&C&D
                """#
                + "\\end{\(name)}")
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("<thead>\n<tr><th"))
        #expect(result.body.contains("</thead><tbody>"))
        #expect(result.body.contains("last dropped"))
        #expect(result.body.contains("data-latex-repeat-foot hidden"))
        #expect(
            result.body.contains(
                #"data-latex-column="p" style="text-align: end; vertical-align: var(--latex-cell-align, top); width: calc(56.9055118 * var(--tex-pt, 0.996264pt))"#
            ))
        #expect(result.body.contains("font-weight: bold; background-color: #ffff00\">A<br>B"))
        #expect(result.body.contains("text-align: center; background-color: #ff00cc\">Q"))
        #expect(
            result.body.contains(
                #"data-latex-column="m" style="text-align: justify; vertical-align: var(--latex-cell-align, middle); width: calc(28.4527559 * var(--tex-pt, 0.996264pt))"#
            ))
        #expect(result.body.contains(#"class="latex-top-light"><span class="latex-middle-cell"><span>C"#))
        #expect(
            result.body.contains(
                #"data-latex-column="b" style="text-align: justify; vertical-align: var(--latex-cell-align, bottom); width: calc(28.4527559 * var(--tex-pt, 0.996264pt))"#
            ))
        #expect(
            result.body.contains(
                #"border-top: var(--latex-arrayrulewidth, calc(.4 * var(--tex-pt, .996264pt))) solid currentColor" class="latex-top-hline"><span class="latex-bottom-cell">D"#
            ))
    }

    @Test("長表の横罫は各表を読み取った時点の arrayrulewidth で組む")
    func longTableRuleWidth() {
        let source = #"""
            \documentclass{article}\begin{document}
            \begin{longtable}{l}First\\\hline\end{longtable}
            {\setlength{\arrayrulewidth}{1.2pt}\begin{longtable}{l}Second\\\hline\end{longtable}}
            \begin{longtable}{l}Third\\\hline\end{longtable}
            \end{document}
            """#
        let result = LaTeXConverter.convert(source)
        #expect(result.readingIssues.isEmpty)
        let tables = result.body.components(separatedBy: "<table").dropFirst()
        #expect(
            tables.map { $0.contains("--latex-arrayrulewidth: calc(1.2 * var(--tex-pt, 0.996264pt))") } == [
                false, true, false,
            ])
        #expect(tables.allSatisfy { $0.contains(#"class="latex-bottom-hline""#) })
    }

    @Test("段落列だけを折り返し、表幅の残りを伸縮列で等分する")
    func flexibleColumns() {
        let result = LaTeXConverter.convert(
            #"""
            \newcolumntype{L}{>{\bfseries}l}
            \begin{tabularx}{.8\linewidth}{@{}Lm{16mm}b{16mm}XX@{}}
            Mark&Before&After&Observation&Trial\\
            \multicolumn{2}{r}{Pair}&One&Two&Three
            \end{tabularx}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains(#"data-latex-tabularx style="width: 80%; --latex-x-share: 50%""#))
        #expect(
            result.body.contains(
                #"<td style="text-align: start; padding-inline-start: 0; font-weight: bold">Mark</td>"#))
        #expect(result.body.contains(#"class="latex-middle-cell"><span>Before</span></span>"#))
        #expect(result.body.contains(#"class="latex-bottom-cell">After</span>"#))
        #expect(result.body.contains(#"data-latex-column="X" style="text-align: justify">Observation"#))
        #expect(result.body.contains(#"<td style="text-align: end" colspan="2">Pair</td>"#))
    }

    @Test("booktabs の太罫・細罫の上下に空きを付け、二重の横罫と段落列の揃えを区別する")
    func booktabsSpacing() {
        let html = LaTeXConverter.convert(
            #"\begin{tabular}{p{4cm}}\toprule Head\\\midrule Text\\\hline\hline More\\\bottomrule\end{tabular}"#
        ).body
        #expect(
            html.contains(
                #"<tr class="latex-below-rule latex-above-rule"><th data-latex-column="p" style="text-align: justify; vertical-align: var(--latex-cell-align, top); width: calc(113.811024 * var(--tex-pt, 0.996264pt))" class="latex-top-heavy">Head"#
            ))
        #expect(
            html.contains(
                #"<tr class="latex-below-rule"><td data-latex-column="p" style="text-align: justify; vertical-align: var(--latex-cell-align, top); width: calc(113.811024 * var(--tex-pt, 0.996264pt))" class="latex-top-light">Text"#
            ))
        #expect(
            html.contains(
                #"<tr class="latex-above-rule"><td data-latex-column="p" style="text-align: justify; vertical-align: var(--latex-cell-align, top); width: calc(113.811024 * var(--tex-pt, 0.996264pt))" class="latex-top-double latex-bottom-heavy">More"#
            ))
    }

    @Test("画像を切り抜いてから指定の幅と高さに収め、倍率と角度を適用する")
    func graphicsOptions() {
        let result = LaTeXConverter.convert(
            #"\includegraphics*[width=.5\linewidth,height=2cm,angle=90,scale=.75,keepaspectratio,trim=0 1 2 3,clip,page=2]{x.png}"#
        )
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains(#"data-latex-transform="0.75 0.75 -90""#))
        #expect(result.body.contains(#"data-latex-crop="0 1 2 3" data-keep-ratio="true""#))
        #expect(result.body.contains("--latex-target-width: 50%; --latex-target-height: calc(56.9055118"))
        #expect(!result.body.contains("page=2"))
    }

    @Test("定義した色と題をテーマの囲みに渡し、引数付きの自作囲みと定理にも適用する")
    func boxes() {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{article}
            \definecolor{Ocean}{HTML}{006688}
            \newtcolorbox{example}[1]{title={#1},colback=yellow!50,colframe=Ocean,unknown=quiet}
            \newtcbtheorem{law}{Law}{colframe=Ocean}{ex}
            \begin{document}
            \begin{example}{A, B}inside\end{example}
            \begin{law}{Motion}{m}content\end{law}\ref{ex:m}
            \tcbox[colback=yellow,colframe=Ocean]{short}
            \begin{mdframed}[frametitle=Extra,backgroundcolor=yellow]middle\end{mdframed}
            \begin{framed}frame\end{framed}\begin{shaded}shade\end{shaded}
            \fbox{plain}\colorbox{red}{red}\fcolorbox{blue}{yellow}{both}
            \end{document}
            """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("--callout-tint: #ffff80; --callout-color: #006688"))
        #expect(result.body.contains("<p class=\"callout-title\">A, B</p>"))
        #expect(result.body.contains("Law 1: Motion"))
        #expect(result.body.contains("<a class=\"latex-number-ref\" href=\"#counter-law-1\">1</a>"))
        #expect(result.body.contains("background-color: #ffff00; border-color: #006688"))
        #expect(result.body.contains("<p class=\"callout-title\">Extra</p>"))
        #expect(result.body.components(separatedBy: "class=\"callout callout-neutral\"").count == 6)
        #expect(result.body.contains("class=\"latex-fbox\">plain"))
        #expect(result.body.contains("border: 0.5pt solid #0000ff"))
        #expect(!result.body.contains("quiet"))
    }

    @Test(
        "和文クラスとそのオプションを読み、見出し・柱・余白・書体・描画設定を本文に出さない",
        arguments: ["jlreq", "ltjsarticle", "ltjsreport", "ltjsbook", "bxjsarticle", "bxjsbook"])
    func quietSettings(name: String) {
        let result = LaTeXConverter.convert(
            "\\documentclass[book]{\(name)}"
                + #"""
                \begin{document}
                \pagestyle{fancy}\fancyhf{}\lhead[ignored]{ignored}\fancyfoot[C]{ignored}
                \newgeometry{ignored}\restoregeometry\setmainjfont[ignored]{ignored}[ignored]
                \newjfontfamily\myfont[ignored]{ignored}\ltjsetparameter{ignored}\myfont
                \titleformat{\section}[hang]{ignored}{ignored}{ignored}{ignored}[ignored]
                \titleformat*{\section}{ignored}\titlespacing*{\section}{ignored}{ignored}{ignored}[ignored]
                \hypersetup{ignored}\pgfplotsset{ignored}\usetikzlibrary{ignored}
                \begin{figure}\caption{題}\end{figure}
                \end{document}
                """#, fontIndex: .testInventory)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("図 1"))
        #expect(!DocumentOutline.plainText(ofHTML: result.body).contains("ignored"))
    }
}
