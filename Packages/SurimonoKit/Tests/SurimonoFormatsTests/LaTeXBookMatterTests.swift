import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXBookMatterTests {
    @Test("比較原稿五件の図・表・式の参照がすべて本文中の宛先に解決する")
    func corpusReferences() throws {
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let corpus = repository.appendingPathComponent("Snapshots/corpus/latex")
        for (folder, targets) in [
            ("108-ltjsbook-parts", ["fig-1.1", "tab-2.1", "eq-2.1"]),
            ("109-scrbook-parts", ["fig-1.1", "tab-2.1", "eq-2.1"]),
            ("110-class-amsproc", ["fig-1", "tab-1", "eq-1"]),
            ("111-ltjarticle-plain", ["fig-1", "tab-1"]),
            ("112-ltjbook-chapters", ["fig-1.1", "tab-2.1"]),
        ] {
            let source = try String(contentsOf: corpus.appendingPathComponent(folder + "/main.tex"), encoding: .utf8)
            let fragment = LaTeXConverter.convert(source)
            #expect(fragment.readingIssues.isEmpty, "比較原稿 \(folder)")
            for id in targets {
                #expect(fragment.body.contains("href=\"#\(id)\""))
                #expect(fragment.body.contains("id=\"\(id)\""))
            }
        }
    }

    @Test("前付と後付の章は目次に載り、本文章と付録だけに番号が付く", arguments: ["ltjsbook", "scrbook", "ltjbook"])
    func matter(_ name: String) {
        let tex = #"""
            \documentclass{\#(name)}
            \begin{document}
            \frontmatter\tableofcontents\chapter{Preface}
            \mainmatter\chapter{Bench}\section{Gauge}\appendix\chapter{Cards}
            \backmatter\chapter{Notes}
            \end{document}
            """#
        let fragment = LaTeXConverter.convert(tex)
        let html = fragment.body
        #expect(fragment.readingIssues.isEmpty)
        #expect(html.contains(#"data-latex-page-action="pagenumbering" data-value="roman""#))
        #expect(html.contains(#"data-latex-page-action="pagenumbering" data-value="arabic""#))
        #expect(html.components(separatedBy: #"data-latex-page-action="pagenumbering""#).count == 3)
        #expect(html.contains(#"data-latex-book-mark="Preface""#))
        #expect(html.contains(#"data-latex-book-mark="Notes""#))
        let toc = html.components(separatedBy: "</nav>")[0]
        #expect(toc.contains(">Preface</a>") && toc.contains(">Notes</a>"))
        #expect(toc.contains("href=\"#sec-1\"") && toc.contains("href=\"#sec-A\""))
        #expect(html.contains(#"<template data-latex-break="right">"#))
    }

    @Test("和文書籍の目次は章ごとの章名と、読み込み時の深さを使う")
    func contents() {
        let tex = #"""
            \documentclass{ltjsbook}\begin{document}
            \tableofcontents\part{架橋}\chapter{芯}\section{材料}\subsection{板厚}
            \appendix\chapter{型紙}\setcounter{tocdepth}{2}\tableofcontents\end{document}
            """#
        let html = LaTeXConverter.convert(tex).body
        let lists = html.components(separatedBy: "<nav").dropFirst().map { $0.components(separatedBy: "</nav>")[0] }
        #expect(lists.count == 2)
        let skip = #"<span class="latex-xkanjiskip"> </span>"#
        #expect(lists.first?.contains("第" + skip + "I" + skip + "部") == true)
        #expect(lists.first?.contains("板厚") == false)
        // Like the .toc LaTeX wrote at each chapter, a list read before \appendix still names the appendix.
        #expect(lists.first?.contains("付録" + skip + "A") == true)
        #expect(lists.first?.contains("第" + skip + "A") == false)
        #expect(lists.last?.contains("板厚") == true)
        #expect(lists.last?.contains("付録" + skip + "A") == true)
    }

    @Test("和文中の引用は接する漢字の側だけを四分空け、句読点と明示した空白を保つ")
    func japaneseCitationSpacing() {
        let tex = #"""
            \documentclass{ltjbook}\begin{document}札\cite{a}を写す。札 \cite{a}。
            \begin{thebibliography}{9}\bibitem{a}『台札』。\end{thebibliography}\end{document}
            """#
        let html = LaTeXConverter.convert(tex).body
        let skip = #"<span class="latex-xkanjiskip"></span>"#
        let cite = ##"<span class="latex-cite">[<a href="#bib-1-1">1</a>]</span>"##
        #expect(html.contains("札" + skip + cite + skip + "を"))
        #expect(html.contains("札 " + cite + "。"))
        #expect(html.contains(#"class="latex-bibliography latex-numbered" style="--latex-label-digits: 1ch""#))
        #expect(html.contains(#"『台札<span class="latex-jfm-close">』</span>。"#))
    }

    @Test("分けて書いた脚注の星印と番号を両端に保ち、明示した番号を対応させる")
    func asteriskFootnotes() {
        let tex = #"""
            \documentclass{ltjsbook}\begin{document}紙\footnotemark[4]と札\footnote{幅}。
            \footnotetext[4]{高さ}\renewcommand{\thefootnote}{\roman{footnote}}棚\footnote{奥行き}\end{document}
            """#
        let html = LaTeXConverter.convert(tex).body
        for (mark, target, note) in [("*4", "4", "高さ"), ("*1", "1", "幅")] {
            #expect(html.contains("id=\"fnref-\(target)\">\(mark)</a>"))
            #expect(html.contains("<sup class=\"latex-symbolic-note\">\(mark)</sup>\(note)"))
        }
        #expect(html.contains("ii</a>"))
        #expect(!html.contains("*ii"))
        let adjacent = LaTeXConverter.convert(#"\documentclass{ltjsbook}\begin{document}紙。\footnote{札}\end{document}"#)
        #expect(adjacent.body.contains(#"<span class="latex-jfm-close">。</span><sup class="footnote-ref">"#))
    }

    @Test("書籍の柱は和文書体と和欧間隔を保持し、欧文の斜体指定を区別する")
    func bookMarkFonts() {
        let tex = #"\documentclass{ltjbook}\begin{document}\chapter{基壇}模型\end{document}"#
        let paper = LaTeXConverter.convert(tex)
        #expect(paper.body.contains("data-latex-book-mark=\"第\u{2005}1\u{2005}章　基壇\""))
        #expect(paper.body.contains(#"<span class="secnum">第 1 章</span>基壇"#))
        #expect(LaTeXPageNumbers.text(#"  \leftmark~\thepage"#, page: "2", left: "第 1 章　基壇") == "第 1 章　基壇 2")
        #expect(paper.latexClass?.japaneseMainFontName == "HiraMinProN-W3")
        #expect(paper.latexClass?.japaneseFurnitureScale == 0.962216)
        let appendix = LaTeXConverter.convert(
            #"\documentclass{ltjbook}\begin{document}\appendix\chapter{保管箱}\end{document}"#)
        #expect(appendix.body.contains(#"data-latex-heading="chapter" data-latex-appendix"#))
        let book = LaTeXConverter.convert(#"\documentclass{scrbook}\begin{document}A\end{document}"#)
        #expect(book.latexClass?.pageHeadFont?.shape == "oblique")
        let koma = LaTeXConverter.convert(
            #"\documentclass{scrbook}\begin{document}\chapter{Bench}\section{Fold}\end{document}"#)
        #expect(koma.body.contains("data-latex-book-mark=\"1\u{2002}Bench\""))
        #expect(koma.body.contains("data-latex-book-mark=\"1.1\u{2002}Fold\""))
    }

    @Test("議事録の定理番号は終止点を伴い、分類年と表題語を元の文字列で保持する")
    func proceedingsLabels() {
        let tex = #"""
            \documentclass{amsproc}\newtheorem{rulethm}{Rule}\title{Fold}\author{Desk}\subjclass[2020]{05B45}
            \begin{document}\begin{abstract}A fold.\end{abstract}\maketitle
            \begin{rulethm}It fits.\end{rulethm}\begin{proof}Fold it.\end{proof}
            \begin{table}\caption{Stops}\end{table}\end{document}
            """#
        let html = LaTeXConverter.convert(tex).body
        #expect(html.contains(#"class="theorem-head">Rule 1.</span>"#))
        #expect(html.contains(#"class="proof-head">Proof.</span>"#))
        #expect(html.contains(#"<span class="latex-msc-year">2020</span> Mathematics Subject Classification."#))
        #expect(html.contains(#"class="latex-caption-label">Table 1</span>"#))
        #expect(html.contains(#"class="latex-abstract-label">Abstract. </strong>"#))
    }

    @Test("KOMA の部と付録は節番号や図表にも終止点を付け、参照番号には付けない")
    func endDots() {
        for (options, suffix) in [("", "."), ("numbers=noenddot", "")] {
            let tex = #"""
                \documentclass[\#(options)]{scrbook}\begin{document}
                \tableofcontents\chapter{Bench}\label{c}\minisec{Shim}
                \begin{figure}\caption{Edge}\end{figure}
                \appendix\chapter{Cards}\backmatter\addchap{Notes}\ref{c}\end{document}
                """#
            let fragment = LaTeXConverter.convert(tex)
            let html = fragment.body
            #expect(fragment.readingIssues.isEmpty)
            #expect(html.contains("<span class=\"secnum\">1\(suffix)</span>Bench"))
            #expect(html.contains("Figure 1.1\(suffix)</span>: Edge"))
            #expect(html.contains("href=\"#sec-1\">1</a>"))
            #expect(html.contains(#"data-latex-koma-heading="minisec">Shim</h6>"#))
            #expect(html.contains(">Notes</a>") && !html.contains(">Shim</a>"))
        }
    }

    @Test("見開きの左右を指定しても前付と本文の番号は右ページから始まる")
    func openingOptions() {
        for (options, matter, chapter) in [
            ("openany", "right", "page"), ("openleft", "right", "left"), ("oneside", "page", "page"),
        ] {
            let tex = "\\documentclass[\(options)]{ltjbook}\\begin{document}\\frontmatter\\chapter{工房}\\end{document}"
            let body = LaTeXConverter.convert(tex).body
            #expect(body.hasPrefix("<template data-latex-break=\"\(matter)\">"))
            #expect(body.contains("<template data-latex-break=\"\(chapter)\"></template><h2"))
        }
        let tex =
            #"\documentclass{scrbook}\begin{document}\frontmatter*\chapter{Start}\mainmatter[Roman]\chapter{Core}\end{document}"#
        let body = LaTeXConverter.convert(tex).body
        #expect(body.contains(#"data-latex-page-action="pagenumbering" data-value="Roman""#))
        #expect(!body.contains(#"data-value="roman""#))
    }

    @Test("和文標準クラスの級数別の版面は実 TeX の寸法になる")
    func traditionalBox() {
        // These are physical PDF points converted from the registers at begin-document.
        for (name, size, width, height, left, top) in [
            ("ltjarticle", 10, 325.778, 590.785, 133.768, 128.787),
            ("ltjarticle", 11, 340.722, 595.766, 126.795, 125.798),
            ("ltjarticle", 12, 370.610, 584.807, 111.851, 131.776),
            ("ltjbook", 10, 325.778, 590.785, 106.869, 127.858),
            ("ltjbook", 11, 340.722, 595.766, 100.892, 124.676),
            ("ltjbook", 12, 370.610, 584.807, 88.936, 128.661),
        ] {
            let info = LaTeXConverter.documentClassInfo("\\documentclass[\(size)pt]{\(name)}")
            let box = info.pageBox
            #expect(abs(box.textWidth - width) < 0.01 && abs(box.textHeight - height) < 0.01)
            #expect(abs(box.left - left) < 0.01 && abs(box.top - top) < 0.01)
            #expect(box.mirrorsSides == (name == "ltjbook"))
        }
    }

    @Test("伝統的書籍では裏面の原点も実 TeX と同じく独立に丸める")
    func versoRegister() throws {
        let box = LaTeXDocumentClassInfo(name: "ltjbook").pageBox
        let even = try #require(box.evenLeft)
        #expect(abs(even - 161.664) < 0.01)
        #expect(abs(box.right - even) > 0.9)
    }

    @Test("伝統的和文クラスの見出し・図の区切り・本文の行送りを保持する")
    func traditionalLabels() {
        for (name, bib) in [("ltjarticle", "参考文献"), ("ltjbook", "関連図書")] {
            let tex = #"""
                \documentclass{\#(name)}\begin{document}\tableofcontents
                \section{台紙}{\Large 端}\begin{figure}\caption{帯}\end{figure}
                \begin{thebibliography}{1}\bibitem{k}工房。\end{thebibliography}\end{document}
                """#
            let result = LaTeXConverter.convert(tex)
            #expect(result.body.contains("目 次</p>") && result.body.contains(">\(bib)</h2>"))
            #expect(result.body.contains(#"data-latex-heading="section""#))
            #expect(result.body.contains("図 1</span>:\u{2002}帯"))
            #expect(result.body.contains("--latex-selected-pitch: calc(21 * var(--tex-pt)"))
            #expect(result.latexClass?.styleVariables.contains("--latex-array-baseline: 15") == true)
        }
    }

    @Test("和文の概要・節・小節は各サイズファイルの行送りで組む")
    func traditionalHeadingPitches() {
        for (option, small, large, section) in [
            ("10pt", "11", "17", "21"), ("11pt", "12", "17", "21"), ("12pt", "13.6", "21", "25"),
        ] {
            let result = LaTeXConverter.convert(
                #"\documentclass[\#(option)]{ltjarticle}\begin{document}\section{工作}紙。\end{document}"#
            )
            for (name, pitch) in [("small", small), ("large", large), ("Large", section)] {
                #expect(
                    result.latexClass?.styleVariables.contains("--latex-pitch-\(name): calc(\(pitch) * var(--tex-pt))")
                        == true)
            }
        }
    }

    @Test("書籍の柱とノンブルは通常ページと章扉で位置と書体を切り替える")
    func bookHeads() {
        for name in ["ltjsbook", "ltjbook", "scrbook"] {
            var page = LaTeXDocumentClassInfo(name: name).pageNumbers
            page.apply("leftmark", value: "Chapter")
            page.apply("rightmark", value: "Section")
            let inHead = name != "scrbook"
            #expect(page.header == (inHead ? ["Section", "", "1"] : ["", "", "Section"]))
            #expect(page.footer == (inHead ? ["", "", ""] : ["", "", "1"]))
            #expect(page.spansOuterMargin == (name == "ltjsbook"))
            #expect((page.ruleWidth("headrulewidth") > 0) == (name == "ltjsbook"))
            page.advance()
            #expect(page.header == (inHead ? ["2", "", "Chapter"] : ["Chapter", "", ""]))
            page.apply("classPlain", value: "")
            #expect(page.header == (inHead ? ["2", "", ""] : ["", "", ""]))
            #expect(page.footer == (inHead ? ["", "", ""] : ["2", "", ""]))
            #expect(page.ruleWidth("headrulewidth") == 0)
            page.advance()
            #expect(page.header.contains("Section"))
        }
    }

    @Test("AMS 論文集の柱は最後の著者を and で結び式番号は既定で左に置く")
    func proceedings() {
        let tex =
            #"\documentclass{amsproc}\author{Fold}\author{Slot}\author{Gauge}\begin{document}\maketitle\end{document}"#
        let result = LaTeXConverter.convert(tex)
        #expect(result.body.contains(#"data-latex-page-action="leftmark" data-value="Fold, Slot, and Gauge""#))
        #expect(result.latexClass?.styleVariables.contains("--latex-eqno-start: 0px") == true)
        let right = LaTeXConverter.documentClassInfo(#"\documentclass[reqno]{amsproc}"#)
        #expect(!right.styleVariables.contains("--latex-eqno-start"))
    }
}
