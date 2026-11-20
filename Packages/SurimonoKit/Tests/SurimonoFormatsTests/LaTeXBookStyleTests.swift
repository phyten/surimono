import Foundation
import SurimonoFormats
import Testing

struct LaTeXBookStyleTests {
    @Test("標準の部と章は番号と折り返し可能な題を分け、星付きの部には番号を置かない")
    func standardOpenings() {
        for name in ["book", "report"] {
            let html = LaTeXConverter.convert(
                #"\documentclass{"# + name + #"}\begin{document}\part{Upper}\chapter{Water}\part*{End}\end{document}"#
            ).body
            #expect(html.contains(#"Part I</span><span class="latex-chapter-title">Upper</span>"#))
            #expect(html.contains(#"Chapter 1</span><span class="latex-chapter-title">Water</span>"#))
            #expect(html.contains(#"id="part-u"><span class="latex-chapter-title">End</span>"#))
        }
    }

    @Test("KOMA 論文は表題を本文内に置き、参考文献にも節の書体を引き継ぐ")
    func articleFrontMatter() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[abstract=true]{scrartcl}
            \begin{document}
            \title{Spacer trial}\subtitle{A bench memorandum}\maketitle
            \setkomafont{section}{\itshape}
            \section{Bench trial}
            \begin{thebibliography}{1}\bibitem{a}Stock\end{thebibliography}
            \end{document}
            """#)
        let info = try #require(fragment.latexClass)
        #expect(info.hasSeparateTitlePage == false)
        #expect(fragment.body.contains(#"class="latex-bibliography-heading" data-latex-koma-heading="section""#))
        #expect(fragment.body.components(separatedBy: "--latex-koma-section-style: italic").count == 3)
        #expect(!fragment.body.contains("data-latex-chapter-opening"))
        #expect(
            LaTeXConverter.documentClassInfo(#"\documentclass[titlepage=true]{scrartcl}"#).hasSeparateTitlePage == true)
        #expect(
            LaTeXConverter.documentClassInfo(#"\documentclass[titlepage,notitlepage]{scrartcl}"#).hasSeparateTitlePage
                == false)
    }

    @Test("KOMA の級数・本文分割・綴じ代は typearea の行格子と左右の比率に従う")
    func typearea() {
        for (options, cls, size, width, height, left) in [
            ("oneside", "scrreprt", 11, 418.25555, 595.80026, 89.6262),
            ("DIV=12,BCOR=8mm", "scrbook", 11, 431.05931, 636.60028, 70.65768),
            ("10pt", "scrartcl", 10, 373.44246, 538, 112.03274),
            ("fontsize=12pt", "scrartcl", 12, 448.13095, 635.5, 74.68849),
        ] {
            let info = LaTeXConverter.documentClassInfo("\\documentclass[\(options)]{\(cls)}")
            #expect(info.pointSize == size)
            let box = info.pageBox
            #expect(box.mirrorsSides == (cls == "scrbook"))
            #expect(abs(box.paperWidth - 595.276) < 0.01)
            for (actual, tex) in zip([box.textWidth, box.textHeight, box.left], [width, height, left]) {
                #expect(abs(actual - tex * 72 / 72.27) < 0.01)
            }
        }
    }

    @Test("KOMA の短い罫だけの図では罫の上下に本文行の余白を加えない")
    func ruleCaption() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{scrreprt}\begin{document}\begin{figure}[ht]\centering\rule{28mm}{2mm}\caption{Side view}\end{figure}\end{document}"#
        )
        #expect(fragment.body.contains(" data-latex-rule-line"))
        #expect(fragment.body.contains("Side view</figcaption>"))
    }

    @Test("A4 以外の既定分割と明示した自動分割はクラスの欧文書体から本文幅を決める")
    func calculatedDivision() {
        for (option, width) in [
            ("letterpaper", 351.02573), ("paper=a5", 330.86494), ("a5paper,twocolumn", 330.86494),
            ("a4paper,DIV=calc", 373.44246), ("a4paper,DIV=classic", 418.25555),
        ] {
            let info = LaTeXConverter.documentClassInfo("\\documentclass[\(option)]{scrreprt}")
            #expect(abs(info.pageBox.textWidth - width * 72 / 72.27) < 0.01)
        }
    }

    @Test("memoir の級数と綴じ方で本文を決め、章書式の変更はその位置から適用する")
    func memoir() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[oneside]{memoir}\chapterstyle{hangnum}\begin{document}
            \chapter{Fold}\chapterstyle{article}\chapter{Cut}\chapterstyle{section}\chapter{Check}
            \chapterstyle{unknown}\chapter{Store}\begin{thebibliography}{1}\bibitem{a}Stock\end{thebibliography}\end{document}
            """#)
        let box = try #require(fragment.latexClass?.pageBox)
        #expect(abs(box.textWidth - 341 * 72 / 72.27) < 0.01)
        #expect(abs(box.left - 135.761) < 0.01)
        #expect(abs(box.top - 123.87) < 0.01)
        for (style, title) in [
            ("hangnum", "1</span>Fold"), ("article", "2</span>Cut"), ("section", "3</span>Check"),
            ("default", "Chapter 4</span>Store"),
        ] {
            #expect(fragment.body.contains("data-latex-memoir-style=\"\(style)\""))
            #expect(fragment.body.contains(title))
        }
        #expect(
            fragment.body.contains(
                #"class="latex-bibliography-heading" data-latex-memoir-style="default" data-latex-chapter-opening"#))
    }

    @Test("本文途中の書体変更はすでに読んだ章や図題にさかのぼらない")
    func localDeclarations() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{scrreprt}\setkomafont{chapter}{\Large}\begin{document}
            \chapter{First}\setkomafont{chapter}{\Huge}\chapter{Second}
            \setkomafont{caption}{\itshape}\begin{figure}\caption{Stock}\end{figure}\end{document}
            """#)
        let info = try #require(fragment.latexClass)
        #expect(info.styleVariables.contains("--latex-koma-chapter-size: calc(14.4"))
        #expect(!info.styleVariables.contains("--latex-koma-caption-style"))
        #expect(
            fragment.body.contains(#"data-latex-koma-heading="chapter" style="--latex-koma-chapter-size: calc(24.88"#))
        #expect(
            fragment.body.contains(#"style="--latex-koma-caption-style: italic; --latex-koma-caption-variant: normal""#)
        )
    }

    @Test("KOMA の書体宣言は役割ごとに置換・追加し、文献に章の書体と改ページを適用する")
    func elementFonts() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{scrreprt}
            \setkomafont{disposition}{\sffamily\bfseries}\addtokomafont{disposition}{\itshape}
            \setkomafont{chapter}{\Large}\addtokomafont{chapter}{\rmfamily}\addtokomafont{section}{\mdseries}
            \setkomafont{caption}{\small}\setkomafont{captionlabel}{\bfseries}
            \setkomafont{pagehead}{\itshape}\setkomafont{pagenumber}{\sffamily\bfseries}
            \begin{document}\chapter{Rails}\section{Cut}\begin{thebibliography}{1}\bibitem{a}Stock\end{thebibliography}\end{document}
            """#)
        let info = try #require(fragment.latexClass)
        for declaration in [
            "disposition-family: var(--tex-sans-fonts)", "disposition-style: italic",
            "chapter-family: var(--tex-body-fonts)",
            "chapter-size: calc(14.4 * var(--tex-pt))", "section-weight: normal",
            "caption-size: calc(10 * var(--tex-pt))",
            "captionlabel-weight: bold", "pagehead-style: italic", "pagenumber-weight: bold",
        ] {
            #expect(info.styleVariables.contains("--latex-koma-" + declaration))
        }
        #expect(
            fragment.body.contains(
                #"class="latex-bibliography-heading" data-latex-koma-heading="chapter" data-latex-chapter-opening"#))
        #expect(info.pageHeadFont?.shape == "italic")
        #expect(info.pageNumberFont?.family == "sans")
        #expect(info.pageNumbers.numberRanges(header: false) == [[], [NSRange(location: 0, length: 1)], []])
    }
}
