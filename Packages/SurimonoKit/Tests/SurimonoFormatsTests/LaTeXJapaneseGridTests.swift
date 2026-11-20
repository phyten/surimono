import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXJapaneseGridTests {
    @Test("リストの表題にも caption の共通設定と種類別の設定が順に届く")
    func listingCaption() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass[11pt]{ltjsarticle}
            \usepackage[font=small]{caption}
            \captionsetup[lstlisting]{labelsep=quad,format=hang}
            \begin{document}
            \begin{lstlisting}[caption={窓の位置}]
            edge = 3
            \end{lstlisting}
            \end{document}
            """#
        ).body
        #expect(html.contains("<figcaption data-latex-caption-style"))
        #expect(html.contains("--latex-caption-pitch: calc(14.235 *"))
        #expect(html.contains("data-latex-caption-hang"))
        #expect(html.contains("Listing 1 </span><span>窓の位置</span>"))
    }

    @Test("和文の独立した式と整列式の上下端を区別し、参考文献を番号なしの節として扱う")
    func displayBaselines() {
        let body = #"""
            \begin{document}
            本文。\[ a=27 \]
            \begin{align*} b &= a+2 \\ c &= b+3 \end{align*}
            \begin{thebibliography}{9}\bibitem{paper}紙札。\end{thebibliography}
            \end{document}
            """#
        let grid = LaTeXConverter.convert(#"\documentclass[11pt]{ltjsarticle}"# + body).body
        #expect(grid.contains("data-latex-single-display"))
        #expect(grid.contains("data-latex-first-baseline") && grid.contains("data-latex-last-baseline"))
        #expect(!grid.contains("latex-row-number"))
        #expect(grid.contains(#"class="latex-bibliography-heading" data-latex-heading="section""#))
        let standard = LaTeXConverter.convert(#"\documentclass{article}"# + body).body
        #expect(!standard.contains("data-latex-single-display") && !standard.contains("data-latex-first-baseline"))
    }

    @Test("和文級数をクラスの倍率で拡大し版面を行送りの整数倍にそろえる")
    func grid() {
        for (size, baseline, top) in [
            ("9pt", 13.69492, 109.53882), ("10pt", 16, 112.71234), ("11pt", 17.52002, 109.55994),
            ("12pt", 19.19995, 117.95091),
        ] {
            for sides in ["oneside", "twoside"] {
                let info = LaTeXConverter.documentClassInfo("\\documentclass[a4paper,\(size),\(sides)]{ltjsreport}")
                #expect(abs(LaTeXLabelMetrics(info).baselines[4] - baseline) < 0.001)
                #expect(abs(info.pageBox.top - top * 72 / 72.27) < 0.02)
                #expect(info.pageBox.mirrorsSides == (sides == "twoside"))
            }
        }
        let jlreq = LaTeXDocumentClassInfo(name: "jlreq", options: "report,fontsize=11pt")
        #expect(abs(jlreq.pageBox.top - 107.15341 * 72 / 72.27) < 0.02)
        #expect(LaTeXLabelMetrics(jlreq).baseline(for: "small") == 14.3)
        let book = LaTeXDocumentClassInfo(name: "ltjsbook")
        #expect(abs(book.pageBox.textWidth - 369.88525 * 72 / 72.27) < 0.02)
        #expect(abs(book.pageBox.top - 110.24812 * 72 / 72.27) < 0.02)
        let bx = LaTeXDocumentClassInfo(name: "bxjsreport", options: "jbase=11pt")
        #expect(abs(LaTeXLabelMetrics(bx).baselines[4] - 19.024) < 0.001)
        #expect(abs(bx.pageBox.top - 102.68365 * 72 / 72.27) < 0.02)
        for (option, scale) in [("8pt", 0.833), ("12Q", 0.923), ("10.5ptj", 1.139), ("43pt", 4.3)] {
            #expect(LaTeXDocumentClassInfo(name: "jsbook", options: option).jsMagnification == scale)
        }
    }

    @Test("節と章の区別を残し、表とコードに本文と小さい級数の行送りを渡す")
    func blocks() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[11pt]{ltjsreport}
            \usepackage[margin=25mm]{geometry}
            \lstset{basicstyle=\small\ttfamily,lineskip=1pt,aboveskip=3pt,belowskip=4pt,xleftmargin=2em}
            \begin{document}
            \chapter{薄片}\section{収納}
            \begin{lstlisting}
            span = 3
            \end{lstlisting}
            \begin{tabularx}{\linewidth}{p{3zw}X}寸法&長辺\end{tabularx}
            \end{document}
            """#)
        #expect(fragment.body.contains(#"data-latex-heading="chapter""#))
        #expect(fragment.body.contains(#"data-latex-heading="section""#))
        #expect(fragment.body.contains("--latex-listing-pitch: calc(14.235 *"))
        #expect(fragment.body.contains("--latex-listing-xleftmargin: 2em"))
        #expect(fragment.body.contains("<colgroup>"))
        #expect(fragment.body.contains("var(--latex-zw, 1ic)"))
        #expect(abs((fragment.latexClass?.pageBox.top ?? 0) - 70.8661) < 0.001)
    }

    @Test("キャプション共通設定に種類別の上書きを重ね、箱と説明リストの宣言を受け継ぐ")
    func settings() {
        let html = LaTeXConverter.convert(
            #"""
            \documentclass{ltjsarticle}
            \usepackage[font=small,labelfont=bf,format=hang,labelsep=period]{caption}
            \captionsetup[table]{labelsep=colon,skip=6pt}
            \tcbset{fonttitle=\bfseries,coltitle=white,left=2mm}
            \newtcolorbox{memo}[1]{title={#1},breakable}
            \setlist[description]{style=nextline,labelwidth=3em}
            \begin{document}
            \begin{figure}\caption{輪}\end{figure}
            \begin{table}\caption{寸法}\end{table}
            \begin{memo}{印}端を揃える。\end{memo}
            \begin{description}\item[縁]輪の外側。\end{description}
            \end{document}
            """#
        ).body
        #expect(html.contains("data-latex-caption-hang"))
        #expect(html.contains("--latex-label-weight: bold"))
        #expect(html.contains("1. </span><span>輪") && html.contains("1: </span><span>寸法"))
        #expect(html.contains("--latex-caption-table-gap: calc(6 *"))
        #expect(html.contains("data-latex-tcolorbox data-latex-breakable"))
        #expect(html.contains("--tcb-title-weight: bold") && html.contains(">印</p>"))
        #expect(html.contains("latex-description latex-nextline") && html.contains("--latex-list-labelwidth: 3em"))
    }

    @Test("倍率を上げたクラスでも setspace の基準は十ポイントのままで、リストの階層別指定を重ねられる")
    func spacing() {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass[11pt]{ltjsarticle}
            \usepackage[onehalfspacing]{setspace}
            \setlist[itemize,2]{itemsep=3pt}
            \begin{document}
            \begin{doublespace}二重の間隔。\end{doublespace}
            \begin{itemize}\item 外\begin{itemize}\item 内\end{itemize}\end{itemize}
            \end{document}
            """#)
        #expect(result.latexClass?.styleVariables.contains("--latex-stretch: 1.25") == true)
        #expect(result.body.contains("--latex-stretch: 1.667"))
        #expect(result.body.components(separatedBy: "--latex-itemsep:").count == 2)
    }

    @Test("和文プリセットを選び個別の書体指定で役割ごとに上書きできる")
    func faces() {
        let info = LaTeXConverter.documentClassInfo(
            #"\documentclass{ltjsarticle}\usepackage[noto-otf]{luatexja-preset}\setsansjfont{Hiragino Sans}\setmonojfont{Example Mono}"#,
            fontIndex: .testInventory
        )
        #expect(info.localFontFaces.contains(#"local("Noto Serif CJK JP")"#))
        #expect(info.localFontFaces.contains(#"local("Hiragino Sans")"#))
        #expect(info.localFontFaces.contains(#"local("Example Mono")"#))
        #expect(info.styleVariables.contains("--latex-cjk-mono-font:"))
    }

    @Test("和文本文の太字にゴシックを割り当て、本文に明示した太字書体を優先する")
    func boldJapaneseFamily() {
        for (options, expected) in [
            ("", "HiraKakuProN-W6"),
            (#"\setsansjfont[BoldFont=YuGo-Bold]{YuGothic}"#, "YuGo-Bold"),
            (#"\setmainjfont[BoldFont=HiraMinProN-W6]{HiraMinProN-W3}\setsansjfont{YuGothic}"#, "HiraMinProN-W6"),
        ] {
            let info = LaTeXConverter.documentClassInfo(
                #"\documentclass{ltjsreport}"# + options, fontIndex: .testInventory)
            let rule = info.localFontFaces.components(separatedBy: "\n").first {
                $0.contains("\"Surimono JS Mincho\"") && $0.contains("font-weight: bold")
            }
            #expect(rule?.contains("src: local(\"\(expected)\")") == true)
            #expect(rule?.contains("unicode-range:") == true)
        }
    }

    @Test("章の段落空きは代入時の本文級数で確定し、目次と無番号章にも和文章の形を残す")
    func chapterRegisters() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{ltjsreport}\linespread{1.15}\setlength{\parskip}{.45em}
            \begin{document}\tableofcontents\chapter{窓}
            \begin{thebibliography}{9}\bibitem{band}帯の資料。\end{thebibliography}
            \end{document}
            """#)
        #expect(fragment.latexClass?.styleVariables.contains("--latex-parskip: calc(4.5 *") == true)
        #expect(
            fragment.body.contains(
                #"<span class="secnum">第<span class="latex-xkanjiskip"> </span>1<span class="latex-xkanjiskip"> </span>章</span>窓</a>"#
            ))
        #expect(fragment.body.contains(#"data-latex-heading="chapter" data-latex-chapter-opening"#))
        #expect(fragment.body.contains("href=\"#bibliography-1\""))
    }

    @Test("箱の名前付き設定と上書き、表の級数と伸長、説明の中央揃えを保つ")
    func scopedBoxAndTable() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[11pt]{ltjsarticle}
            \tcbset{strip/.style={boxsep=1mm,left=2mm,right=2mm,leftrule=0.3mm}}
            \newtcolorbox{slip}[1][]{strip,#1}
            \captionsetup{format=hang,justification=centering}
            \begin{document}
            \begin{slip}[leftupper=3mm,title=端]紙片。\end{slip}
            {\small\renewcommand{\arraystretch}{1.25}\setlength{\tabcolsep}{8pt}
            \begin{longtable}[l]{lp{.4\linewidth}}寸法&印\end{longtable}}
            \begin{figure}\caption{細い印。\\長い印。}\end{figure}
            \end{document}
            """#)
        #expect(fragment.body.contains("--tcb-leftupper: calc(8.535"))
        #expect(fragment.body.contains("--tcb-leftrule: calc(0.853"))
        #expect(fragment.body.contains("--latex-array-baseline: 14.235"))
        #expect(fragment.body.contains("--latex-arraystretch: 1.25"))
        #expect(fragment.body.contains("--latex-tabcolsep: calc(8 *") && fragment.body.contains("--latex-ltleft: 0px"))
        #expect(fragment.latexClass?.styleVariables.contains("--latex-tabcolsep: calc(8 *") == false)
        #expect(fragment.body.contains("var(--latex-table-measure, 100%)"))
        #expect(
            fragment.body.contains("--latex-caption-align: center")
                && !fragment.body.contains("data-latex-caption-hang"))
    }

    @Test("表紙の伸びる空きと空の著者行を残し、横組みの部扉だけを無番号にする")
    func frontPages() {
        let title = LaTeXConverter.convert(
            #"\documentclass{article}\author{}\title{端}\begin{document}\maketitle\begin{titlepage}上\vfill 下\end{titlepage}\end{document}"#
        )
        #expect(title.body.contains("latex-empty-author") && title.body.contains("latex-vfill"))
        let part = LaTeXConverter.convert(#"\documentclass[report]{jlreq}\begin{document}\part{準備}\end{document}"#)
        #expect(part.body.contains(#"class="latex-part" data-latex-page-action="thispagestyle" data-value="empty""#))
    }
}
