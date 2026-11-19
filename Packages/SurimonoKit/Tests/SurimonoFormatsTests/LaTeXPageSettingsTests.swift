import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXPageSettingsTests {
    private func document(_ preamble: String, body: String = "Ink", options: String = "a4paper") -> HTMLFragment {
        LaTeXConverter.convert(
            "\\documentclass[\(options)]{article}\n\(preamble)\n\\begin{document}\n\(body)\n\\end{document}")
    }

    @Test(
        "用紙寸法と左右余白・本文幅から組版幅を求める",
        arguments: [
            (#"\usepackage[margin=25mm]{geometry}"#, "160mm"),
            (#"\usepackage[left=10mm,right=3cm,top=10mm,bottom=3mm]{geometry}"#, "170mm"),
            (#"\usepackage[inner=12mm,outer=32mm,letterpaper]{geometry}"#, "171.9mm"),
            (#"\usepackage[lmargin=14mm,rmargin=28mm]{geometry}"#, "168mm"),
            (#"\usepackage[hmargin={13mm,21mm},vmargin={21mm,17mm}]{geometry}"#, "176mm"),
            (#"\usepackage[margin={23mm,13mm}]{geometry}"#, "164mm"),
            (#"\usepackage[total={123mm,165mm},includehead,includefoot]{geometry}"#, "123mm"),
            (#"\usepackage[textwidth=101mm,textheight=13cm]{geometry}"#, "101mm"),
            (#"\usepackage{geometry}\geometry{b5paper,scale={0.75,0.8}}"#, "132mm"),
            (#"\usepackage[landscape,hscale=0.5]{geometry}"#, "148.5mm"),
            (#"\usepackage[left=20mm]{geometry}"#, "158.5mm"),
            (#"\usepackage[hmargin=2cm,textwidth=12cm]{geometry}"#, "170mm"),
            (#"\usepackage[margin=2cm]{geometry}\setlength{\textwidth}{13cm}"#, "130mm"),
            (
                #"\setlength{\textwidth}{125mm}\setlength{\oddsidemargin}{-1cm}\evensidemargin=12pt\topmargin=-10pt"#,
                "125mm"
            ),
            (#"\usepackage{fullpage}"#, "159.2mm"),
            (#"\usepackage{a4wide}"#, "149.225mm"),
        ])
    func measure(_ input: (String, String)) throws {
        let result = document(input.0)
        let info = try #require(result.latexClass)
        #expect(info.styleVariables.contains("--latex-text-width: \(input.1)"))
        #expect(info.styleVariables.contains("--latex-margin-left:"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("フォントの役割・強調書体・倍率をローカル書体の候補として渡す")
    func localFaces() throws {
        let result = document(
            #"""
            \setmainfont[BoldFont={YuMincho Demibold},ItalicFont={Local Italic},Scale=1.1]{YuMincho}
            \setsansfont{Example Sans}\setmonofont{Example Mono}[Scale=.9]
            \setCJKmainfont{Songti SC}\setsansjfont{Hiragino Sans}
            \newfontfamily\displayface[BoldFont={* Bold}]{Example Display}
            """#, body: #"{\displayface Heading} rest"#)
        let info = try #require(result.latexClass)
        #expect(
            info.styleVariables.contains(
                "--latex-main-font: \"Surimono Mincho Ideographs\", \"Surimono TeX Local 1\", \"YuMincho\""))
        #expect(info.styleVariables.contains("--latex-mono-font:"))
        #expect(info.styleVariables.contains("--latex-sans-font: \"Example Sans\""))
        #expect(info.styleVariables.contains("--latex-cjk-main-font:"))
        #expect(info.styleVariables.contains("--latex-cjk-sans-font:"))
        #expect(info.localFontFaces.contains("local(\"YuMincho Demibold\"); font-weight: bold;"))
        #expect(info.localFontFaces.contains("local(\"Local Italic\"); font-style: italic;"))
        #expect(info.localFontFaces.contains("size-adjust: 110%"))
        #expect(info.localFontFaces.contains("size-adjust: 90%"))
        #expect(info.localFontFaces.contains("local(\"Songti SC\"); unicode-range:"))
        #expect(info.localFontFaces.contains("local(\"Example Display Bold\")"))
        #expect(!info.localFontFaces.contains("url("))
        #expect(result.body.contains("class=\"latex-font-family\""))
        #expect(result.body.contains("Heading</span> rest"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("外部ファイルの指定とスタイルを壊す書体名は書体の要求にしない")
    func ignoresUnsafeFontNames() throws {
        let result = document(#"\setmainfont{https://assets.test/font.ttf}\setsansfont{X";color:red}"#)
        let info = try #require(result.latexClass)
        #expect(!info.styleVariables.contains("-font:"))
        #expect(info.localFontFaces.isEmpty)
        #expect(!result.body.contains("assets"))
    }

    @Test(
        "欧文書体パッケージを役割別に割り当てる",
        arguments: [
            ("times", "main", "Times New Roman"), ("mathptmx", "main", "Times New Roman"),
            ("newtxtext", "main", "Times New Roman"), ("helvet", "sans", "Helvetica Neue"),
            ("palatino", "main", "Palatino"), ("mathpazo", "main", "Palatino"),
            ("newpxtext", "main", "Palatino"), ("courier", "mono", "Courier New"),
            ("lmodern", "main", "Surimono Computer Modern"), ("cm-super", "main", "Surimono Computer Modern"),
            ("libertine", "main", "Linux Libertine O"),
        ])
    func packages(_ input: (String, String, String)) throws {
        let info = try #require(document("\\usepackage{\(input.0)}").latexClass)
        #expect(info.styleVariables.contains("--latex-\(input.1)-font: \"\(input.2)\""))
    }

    @Test("babel の本文書体と字形指定は fontspec と同じローカル書体として読む")
    func babelFont() throws {
        let result = document(
            #"\babelprovide[import,main]{arabic}\babelfont{rm}[ItalicFont={Desk Italic}]{Desk Serif}"#)
        let info = try #require(result.latexClass)
        #expect(info.styleVariables.contains("Desk Serif"))
        #expect(info.localFontFaces.contains(#"local("Desk Italic")"#))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("段落の余白と字下げはパッケージ・クラス指定・長さの代入に従う")
    func paragraphs() throws {
        let source = #"\newcommand{\topic}[1]{\section*{#1}}"#
        let result = document(source, body: #"\parindent=0pt\parskip=4pt plus 1pt\topic{Ink}\noindent\textbf{語：} 紙"#)
        let info = try #require(result.latexClass)
        #expect(info.styleVariables.contains("--latex-parindent: 0pt"))
        #expect(info.styleVariables.contains("--latex-parskip: 4pt"))
        #expect(result.body.contains("<p class=\"latex-noindent\"><strong>語：</strong>"))
        let defaults = try #require(document(#"\usepackage{parskip}"#).latexClass)
        #expect(defaults.styleVariables.contains("--latex-parskip: 0.5lh"))
        let changed = try #require(document(#"\usepackage[skip=8pt,indent=1em]{parskip}"#).latexClass)
        #expect(changed.styleVariables.contains("--latex-parindent: 1em"))
        #expect(changed.styleVariables.contains("--latex-parskip: 8pt"))
        let classOption = try #require(document("", options: "parskip=full").latexClass)
        #expect(classOption.styleVariables.contains("--latex-parskip: 1lh"))
    }

    @Test("組版設定は引数だけを消費し独自の列とリストには指定が効く")
    func quiet() throws {
        let result = document(
            #"\newcolumntype{Y}{>{\raggedleft\bfseries\arraybackslash}X}\setlist[itemize]{nosep,leftmargin=3em}\tcbset{colback=red}"#,
            body: #"""
                \raggedbottom\flushbottom\sloppy
                \XeTeXlinebreaklocale "ja"\XeTeXlinebreakskip=0pt plus 0.1em
                \emergencystretch=3em\hyphenpenalty=175\widowpenalty=100\clubpenalty=100
                Preserved.
                \begin{itemize}\item red\end{itemize}
                \begin{tabular}{lY}First & Second\\\end{tabular}
                """#)
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("<p>Preserved.</p>"))
        #expect(result.body.contains("--latex-list-margin: 3em"))
        #expect(result.body.contains("--latex-itemsep: 0pt"))
        #expect(result.body.contains("text-align: right; font-weight: bold"))
        #expect(result.latexClass?.mainLanguage == "ja")
    }

    @Test(
        "行送りは宣言とsetspaceのクラス別倍率に従う",
        arguments: [
            (#"\linespread{1.2}"#, "10pt", "1.2"),
            (#"\usepackage{setspace}\setstretch{1.4}"#, "10pt", "1.4"),
            (#"\onehalfspacing"#, "11pt", "1.213"),
            (#"\usepackage[doublespacing]{setspace}"#, "12pt", "1.655"),
        ])
    func lineSpacing(_ input: (String, String, String)) throws {
        let info = try #require(document(input.0, options: input.1).latexClass)
        #expect(info.styleVariables.contains("--latex-stretch: \(input.2)"))
    }
}
