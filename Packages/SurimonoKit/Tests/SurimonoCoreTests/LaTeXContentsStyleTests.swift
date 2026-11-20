import SurimonoFormats
import Testing

@testable import SurimonoCore

struct LaTeXContentsStyleTests {
    @Test("目次の章または記事の節は点線なしで一字あけ、図表と下位の項目は本文書体の点線を使う")
    func leadersAndFaces() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let body = HTMLDocumentBuilder.build(
            fragment: LaTeXConverter.convert(
                #"\documentclass{ltjsarticle}\begin{document}\tableofcontents\section{地図}\subsection{左岸}\end{document}"#
            ),
            format: .latex, theme: theme)
        #expect(body.contains(" data-latex-js-toc"))
        #expect(body.contains("nav.toc li > a { font-weight: normal; }"))
        #expect(
            body.contains(
                "--latex-leader-pitch: calc((.278 + var(--latex-toc-dotsep) / 9) * 1em); --latex-leader-diameter: .108em"
            ))
        #expect(body.contains("var(--latex-leader-pitch) 100% repeat-x"))
        #expect(body.contains("body.format-latex nav.toc .latex-page-entry:has(.latex-leader-dots)"))
        #expect(body.contains(".latex-page-leader { flex: 1 0 0; background: none; }"))
        #expect(
            body.contains("font-family: var(--tex-sans-fonts); font-weight: normal; --latex-toc-number-width: 3.7em;"))
    }

    @Test("伝統和文の概要・目次・箇条書きと図表名はクラスのグルーを使う")
    func traditionalVerticalGlue() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        #expect(theme.css.contains("line-height: var(--latex-pitch-small)"))
        #expect(theme.css.contains("var(--j-list-topsep) + var(--j-partopsep) - .5em"))
        #expect(
            theme.css.contains(
                "var(--latex-itemsep, var(--j-list-parsep)) + var(--latex-list-parsep, var(--j-list-parsep))"))
        #expect(theme.css.contains(".latex-caption-label { word-spacing: .083em; }"))
        #expect(theme.css.contains(".latex-contents-title,.abstract-title) { word-spacing: .125em; }"))
        #expect(theme.css.contains("calc(.12em * var(--latex-jfm-scale) + var(--tex-pt))"))
    }

    @Test("和文の見出し・表・脚注と欧文書籍の目次・リストがクラスの寸法を使う")
    func classLengths() throws {
        let themes = try PrintThemeLibrary.load()
        let traditional = try #require(themes.first { $0.id == "latex-plain-ja" })
        let koma = try #require(themes.first { $0.id == "latex-report" })
        let proceedings = try #require(themes.first { $0.id == "latex-article" })
        #expect(traditional.css.contains(#".latex-jfm-close { font-feature-settings: "halt"; }"#))
        #expect(traditional.css.contains("padding-inline-start: var(--latex-list-margin, calc(3 * var(--latex-zw)))"))
        #expect(traditional.css.contains("line-height: var(--tex-baseline); min-height: var(--tex-baseline)"))
        #expect(traditional.css.contains("margin-block: var(--latex-abovecaptionskip) var(--latex-belowcaptionskip)"))
        #expect(
            koma.css.contains("--latex-footnote-rule-width: calc(.4 * var(--latex-text-width-tex-pt) * var(--tex-pt))"))
        #expect(
            koma.css.contains(
                "var(--latex-itemsep, 4.5 * var(--tex-pt)) + var(--latex-list-parsep, 4.5 * var(--tex-pt))"))
        #expect(proceedings.css.contains(#"font-feature-settings: "smcp""#))
        #expect(proceedings.css.contains("width: .65em; height: .65em"))
    }
}
