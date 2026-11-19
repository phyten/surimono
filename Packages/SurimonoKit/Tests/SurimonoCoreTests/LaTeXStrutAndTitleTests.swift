import SurimonoFormats
import Testing

@testable import SurimonoCore

struct LaTeXStrutAndTitleTests {
    @Test("長い表の行高は級数・配列の倍率・追加の高さに従い、グループを出れば元に戻る")
    func tableStruts() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass[11pt]{article}
            \begin{document}
            {\renewcommand{\arraystretch}{1.5}\setlength{\extrarowheight}{2pt}
            \begin{longtable}{ll}A&B\\C&D\end{longtable}}
            \begin{tabular}{ll}E&F\end{tabular}
            \end{document}
            """#)
        #expect(fragment.latexClass?.styleVariables.contains("--latex-array-baseline: 13.6") == true)
        #expect(
            fragment.body.contains(
                #"class="latex-tabular latex-longtable" style="--latex-arraystretch: 1.5; --latex-extrarowheight: calc(2 * var(--tex-pt, 0.996264pt))""#
            ))
        #expect(fragment.body.contains(#"<table class="latex-tabular">"#))
        let css = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" }).css
        #expect(css.contains("var(--latex-extrarowheight, 0px)) * var(--latex-arraystretch, 1)"))
    }

    @Test(
        "表題の直前の空きは標準クラスの titlepage と notitlepage、和文の章の設定に従う",
        arguments: [
            ("article", "", "inline", false), ("article", "titlepage", "separate", false),
            ("report", "", "separate", false), ("report", "notitlepage", "inline", false),
            ("ltjsreport", "", "separate", true), ("ltjsarticle", "", "inline", false),
        ])
    func titlePlacement(_ sample: (String, String, String, Bool)) throws {
        let (cls, option, mode, japaneseChapter) = sample
        let fragment = LaTeXConverter.convert(
            #"\documentclass[\#(option)]{\#(cls)}\begin{document}\title{First}\maketitle A\newpage\section*{Next}B\end{document}"#
        )
        let info = try #require(fragment.latexClass)
        let style = try #require(
            PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.defaultLaTeXStyle(for: info) })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: style)
        #expect(html.contains("data-latex-title-layout=\"\(mode)\""))
        #expect(info.usesJSChapterSpacing == japaneseChapter)
        #expect(style.css.contains("3em + var(--tex-top-sep)"))
        #expect(style.css.contains(".latex-pagebreak + :is(h2,h3,h4,h5,h6)"))
    }
}
