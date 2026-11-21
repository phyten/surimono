import SurimonoCore
import Testing

struct LaTeXTypesettingTests {
    @Test("欧文記事の節間隔は言語の指定と独立に本文のローカル書体を識別する")
    func sectionFontMetrics() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        for (preamble, local) in [
            (#"\usepackage[dutch]{babel}"#, false),
            (#"\usepackage{lmodern}"#, false),
            (#"\setsansfont{Helvetica Neue}"#, false),
            (#"\setmainfont{Times New Roman}"#, true),
            (#"\usepackage{babel}\babelprovide[import,main]{greek}\babelfont{rm}{Times New Roman}"#, true),
            (#"\setmainfont{Hiragino Mincho ProN}"#, true),
        ] {
            let fragment = LaTeXConverter.convert(
                #"\documentclass{article}\#(preamble)\begin{document}\section{One}Two\end{document}"#,
                fontIndex: .init(faces: [:]))
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            let body = try #require(html.components(separatedBy: "<body ").last?.prefix { $0 != ">" })
            #expect(body.contains(" data-latex-local-main-font") == local)
        }
    }

    @Test("LaTeX 専用スタイルは追い込み見出しの短い最終行を行頭に寄せる")
    func runInLastLine() throws {
        let themes = try PrintThemeLibrary.load().filter { $0.id.hasPrefix("latex-") }
        #expect(themes.count == 6)
        for theme in themes {
            #expect(theme.css.contains(".latex-runin { margin-block-start: 1.4em; text-align-last: start; }"))
        }
    }

    @Test("どの専用スタイルでも、所属は中央、章頭の題辞と出典は行末に置く")
    func affiliationsAndEpigraph() throws {
        let themes = try PrintThemeLibrary.load().filter { $0.id.hasPrefix("latex-") }
        for theme in themes {
            #expect(theme.css.contains(".latex-front-affiliations .latex-front-affiliation { text-align: center;"))
            #expect(theme.css.contains(".latex-epigraph p, .latex-epigraph footer { text-align: end;"))
            #expect(theme.css.contains(".latex-epigraph footer { border-block-start: 0.5pt solid currentColor;"))
        }
    }

    @Test("リストの枠を番号の基準にし、文書の字級に合わせて枠の外に小さく刷る")
    func listingNumberGutter() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        #expect(theme.css.contains(".latex-numbered-listing pre { position: relative; overflow: visible; }"))
        #expect(theme.css.contains("inset-inline-end: calc(100% + 0.7em)"))
        #expect(theme.css.contains(".code-line[data-no]::before { width: max-content; white-space: nowrap; }"))
        #expect(theme.css.contains("color: var(--latex-number-ink, #666)"))
        #expect(theme.css.contains("--latex-number-tiny: calc(5 * var(--tex-pt))"))
        #expect(theme.css.contains("--latex-number-tiny: calc(6 * var(--tex-pt))"))
        #expect(theme.css.contains("--latex-number-scriptsize: calc(8 * var(--tex-pt))"))
    }

    @Test(
        "LaTeX の文字サイズオプションが HTML 本体に届き、大きさに応じて行送り・本文幅・字下げが変わる",
        arguments: [10, 11, 12])
    func classSize(_ size: Int) throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let fragment = LaTeXConverter.convert(
            "\\documentclass[twocolumn,\(size)pt]{article}\\begin{document}text\\end{document}")
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        #expect(html.contains("data-latex-size=\"\(size)\" data-latex-chapters=\"false\""))
        #expect(html.contains("--tex-body: 10; --tex-baseline: 15px; --tex-width: 345; --tex-indent: 15"))
        #expect(html.contains("--tex-body: 10.95; --tex-baseline: 17px; --tex-width: 360; --tex-indent: 17"))
        #expect(html.contains("--tex-body: 12; --tex-baseline: 18px; --tex-width: 390; --tex-indent: 17.6"))
        #expect(theme.css.contains("max-width: var(--latex-class-width, calc(var(--tex-width) * var(--tex-pt)))"))
        #expect(theme.css.contains("padding-block-start: 0;"))
        #expect(theme.css.contains("figure.latex-listing { margin-inline: 0; }"))
        #expect(theme.css.contains("--latex-heavy-rule: 0.08em; --latex-light-rule: 0.05em"))
        #expect(theme.css.contains(".math-inline, .math-display { font-size: calc(1em / 1.1)"))
    }

    @Test("欧文の語間とハイフネーションを組版に合わせ、コードと数式の語間は保つ")
    func wordSpacing() throws {
        let themes = try PrintThemeLibrary.load()
        for id in ["latex-article", "latex-report", "latex-plain-ja"] {
            let theme = try #require(themes.first { $0.id == id })
            #expect(!theme.css.contains("body { word-spacing: 0.083em; }"))
            #expect(theme.css.contains("code, pre, .math { word-spacing: normal; }"))
            #expect(theme.css.contains("-webkit-hyphenate-limit-before: 2; -webkit-hyphenate-limit-after: 3"))
            #expect(!theme.css.contains("\n.latex-title-block h1 { letter-spacing: -0.02em; }"))
        }
    }

    @Test("入れ子の箇条書きは四段の印を欄外に置き、項目の間とリストの前後の空きを級数で切り替える")
    func itemize() throws {
        let css = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" }).css
        let rules = css.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(rules.contains(".latex-item-mark { display: inline-block; width: 1em;"))
        #expect(rules.contains("margin-inline: calc(-1em - var(--latex-list-labelsep, .5em))"))
        for pair in ["6; --tex-top-sep: 8", "6.5; --tex-top-sep: 9", "7.5; --tex-top-sep: 10"] {
            #expect(css.contains("--tex-item-sep: " + pair))
        }
    }

    @Test("字下げした行でもロゴや箱の中に二重の字下げを作らず、短い引用は行頭をそろえる")
    func inlineBoxIndentation() throws {
        let css = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" }).css
        let rules = css.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(
            rules.contains(
                ".format-latex :is(.latex-logo, .latex-minipage, .item-label, .bib-label, .latex-hspace, .latex-symbolic-note, .paper-footnote-room) { text-indent: 0; }"
            ))
        #expect(css.contains(".format-latex .latex-minipage p { text-indent: 0; }"))
        #expect(css.contains("max-width: 100%; text-align: justify; text-align-last: auto; }"))
        #expect(css.contains("blockquote:not([class]) > p { text-indent: 0; }"))
        #expect(css.contains(".latex-description dd { display: inline; margin: 0; margin-inline-start: 1em; }"))
    }

    @Test("表の中罫は上下に空きをとり、上下の太罫は同じ厚さ、二重罫は 2pt 離す")
    func tableRules() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        #expect(theme.css.contains("padding-block-end: 0.4ex"))
        #expect(theme.css.contains("padding-block-start: 0.65ex"))
        #expect(
            theme.css.contains(
                #".latex-top-heavy::before, .latex-bottom-heavy::after { border-block-start-width: calc(10 * var(--latex-heavy-rule))"#
            ))
        #expect(theme.css.contains("border-block: calc(4 * var(--tex-pt)) solid currentColor"))
        #expect(theme.css.contains("block-size: calc(20 * var(--tex-pt))"))
    }

    @Test("数値の文献ラベルは本文の外の同じ位置で右にそろえ、折返した行と本文の書き出しがそろう")
    func bibliographyLabelAlignment() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        #expect(
            theme.css.contains(
                "ol.latex-bibliography.latex-numbered { padding-inline-start: calc(var(--latex-label-digits) + 0.56em + 0.5em)"
            ))
        #expect(theme.css.contains("position: absolute; inset-inline-end: calc(100% + 0.5em)"))
        #expect(
            theme.css.contains(
                "width: calc(var(--latex-label-digits) + 0.56em); min-width: 0; margin: 0; text-align: end"))
    }

    @Test("同じ断片から専用スタイルは実寸、既存スタイルは用紙の幅に対する割合で箱を組む")
    func physicalBoxWidthAcrossStyles() throws {
        let themes = try PrintThemeLibrary.load()
        let fragment = LaTeXConverter.convert(
            #"\begin{minipage}{.5\linewidth}\parbox{2.54cm}{X}\end{minipage}"#, textWidthPoints: 510)
        for id in ["latex", "latex-article", "latex-report", "latex-plain-ja"] {
            let theme = try #require(themes.first { $0.id == id })
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            #expect(html.contains("width: 50%;"))
            #expect(html.contains("--latex-box-points: 72; width: var(--latex-measured-width, 28.2353%)"))
            #expect(
                theme.css.contains("--latex-measured-width: calc(var(--latex-box-points) * 1.25px)") == (id != "latex"))
        }
    }

    @Test("報告書は題と章に改ページを設け、和文は全サイズで全角字下げ、明朝の本文とゴシックの見出しを使う")
    func classStyles() throws {
        let themes = try PrintThemeLibrary.load()
        let report = try #require(themes.first { $0.id == "latex-report" })
        let japanese = try #require(themes.first { $0.id == "latex-plain-ja" })
        #expect(report.css.contains(#"h2[id^="sec-"]"#))
        #expect(report.css.contains("padding-block-start: min(37vh, 28em)"))
        #expect(report.css.contains("break-before: page"))
        #expect(report.css.contains("break-after: page"))
        #expect(japanese.css.contains("body[data-latex-size], body"))
        #expect(
            japanese.css.contains("line-height: calc(21px * var(--latex-stretch, 1)); --tex-indent: var(--tex-body)"))
        #expect(
            japanese.css.contains(#"body[data-latex-size="11"] { line-height: calc(23px * var(--latex-stretch, 1)); }"#)
        )
        #expect(
            japanese.css.contains(#"body[data-latex-size="12"] { line-height: calc(25px * var(--latex-stretch, 1)); }"#)
        )
        #expect(japanese.css.contains("max-width: var(--latex-class-width, 49em)"))
        #expect(
            japanese.css.contains(
                ":is(h1, h2, h3, h4, h5, h6) + p { text-indent: var(--latex-parindent, var(--latex-class-indent, 1em)); }"
            ))
        #expect(japanese.css.contains(".latex-title-block h1 { font-family: inherit; }"))
        #expect(japanese.css.contains("font-style: italic; font-synthesis: none"))
        #expect(japanese.css.contains("table.latex-tabular :is(th, td) { line-height: var(--tex-baseline); }"))
        #expect(japanese.css.contains(#""Hiragino Mincho ProN""#))
        #expect(japanese.css.contains(#""Hiragino Kaku Gothic ProN""#))
        let original = try #require(themes.first { $0.id == "latex" })
        #expect(!original.css.contains("--tex-width: 345"))
    }

    @Test("報告書の目次は大見出しと章間の空きを持ち、概要を独立したページの本文幅で組む")
    func reportFrontMatter() throws {
        let report = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        #expect(
            report.css.contains(
                "padding-block-start: var(--tex-chapter-top, calc((50 + var(--tex-body)) * var(--tex-pt) + var(--tex-baseline)))"
            ))
        #expect(report.css.contains("--tex-toc-title: 20.74"))
        #expect(report.css.contains("--tex-toc-title: 24.88"))
        #expect(report.css.contains(".latex-toc-chapter { margin-block-start: 1em; }"))
        #expect(report.css.contains(".latex-toc-chapter > a { font-weight: bold; }"))
        #expect(report.css.contains("break-before: page; page-break-before: always; break-after: page;"))
        #expect(report.css.contains("padding-block-start: min(33vh, 24em); font-size: inherit"))
        #expect(report.css.contains(".abstract p { text-indent: 0; }"))
        #expect(report.css.contains(".abstract-title { text-align: center; font-weight: bold;"))
    }

    @Test("専用スタイルは脚注を一件単位で改ページし、謝辞の記号は本文と同じ行に組む")
    func individualFootnotes() throws {
        let article = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        #expect(article.css.contains(".footnotes > ol > li {"))
        #expect(article.css.contains("margin-block: 0.15em;\n    break-inside: avoid; page-break-inside: avoid;"))
        #expect(article.css.contains(".footnotes .latex-symbolic-note {\n    display: inline-block;"))
    }
}

extension LaTeXTypesettingTests {
    @Test("専用スタイルは指定幅を実寸で組み、本文の書体と独立した絶対字級で副題を小さくする")
    func documentTypography() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass[a4paper]{article}\usepackage[margin=25mm]{geometry}\setmainfont[BoldFont=Face B]{Face A}\title{Title\\\large Subtitle}\begin{document}\maketitle\end{document}"#,
            fontIndex: .init(faces: [:])
        )
        for theme in try PrintThemeLibrary.load() where theme.category == "latex" {
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            #expect(html.contains("--latex-text-width: 160mm"))
            #expect(html.contains("--tex-pt: 1.24533px"))
            #expect(html.contains("--tex-large: 12; --tex-Large: 14.4; --tex-LARGE: 17.28"))
            #expect(html.contains("font-size: calc(var(--tex-LARGE) * var(--tex-pt))"))
            #expect(html.contains("--latex-size-large: calc(var(--tex-large) * var(--tex-pt))"))
            #expect(html.contains(#"src: local("Face B")"#))
            #expect(html.contains("display: inline-block; vertical-align: top; text-align: center"))
            #expect(html.contains(#"body[data-latex-chapters="true"] h2[id^="sec-"]"#))
            let sheet = try #require(html.range(of: "--tex-pt:"))
            let local = try #require(html.range(of: #"src: local("Face B")"#))
            #expect(sheet.lowerBound < local.lowerBound)
        }
    }

    @Test("前置きの言語で中韓のスタイルを選び、欧文クラスの和文は元の版面を保つ")
    func defaultClassStyle() {
        for (preamble, expected) in [
            (#"\documentclass{article}\usepackage{kotex}"#, "latex-plain-ko"),
            (#"\documentclass{report}\setmainlanguage{chinese}"#, "latex-plain-zh"),
            (#"\documentclass{article}\XeTeXlinebreaklocale "ja""#, "latex-article"),
            (#"\documentclass{report}\usepackage[japanese]{babel}"#, "latex-report"),
            (#"\documentclass{ltjsreport}"#, "latex-plain-ja"),
        ] {
            let info = LaTeXConverter.documentClassInfo(preamble + #"\begin{document}文\end{document}"#)
            #expect(PrintThemeLibrary.defaultLaTeXStyle(for: info) == expected)
        }
    }

    @Test("中韓の専用スタイルと欧文の多言語フォールバックを紙に渡す")
    func scriptsAndDirection() throws {
        let themes = try PrintThemeLibrary.load()
        for (id, language, family) in [
            ("latex-plain-zh", "zh-Hans", "Songti SC"), ("latex-plain-zh", "zh-Hant", "Songti TC"),
            ("latex-plain-ko", "ko", "AppleMyungjo"), ("latex-article", "ru", "Times New Roman"),
            ("latex-report", "el", "Times New Roman"), ("latex-article", "ar", "Geeza Pro"),
            ("latex-report", "he", "Arial Hebrew"),
        ] {
            let theme = try #require(themes.first { $0.id == id })
            let html = HTMLDocumentBuilder.build(
                fragment: HTMLFragment(body: "<p>x</p>", language: language), format: .latex, theme: theme)
            #expect(html.contains("<html lang=\"\(language)\""))
            #expect(html.contains(family))
            #expect(html.contains("<html lang=\"\(language)\" dir=\"rtl\">") == ["ar", "he"].contains(language))
        }
    }
}
