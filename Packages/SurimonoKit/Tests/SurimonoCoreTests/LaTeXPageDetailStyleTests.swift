import Foundation
import SurimonoCore
import SurimonoFormats
import Testing

struct LaTeXPageDetailStyleTests {
    @Test("章のある本では部の題を独立した用紙の中央に、文献見出しを改ページ後に置く")
    func chapterBreaks() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let tex =
            #"\documentclass{book}\begin{document}\part{Paper}\begin{thebibliography}{1}\bibitem{a}Book\end{thebibliography}\end{document}"#
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(tex), format: .latex, theme: theme)
        #expect(html.contains(#"<span class="secnum">Part I</span><span class="latex-chapter-title">Paper</span>"#))
        #expect(html.contains(#"body[data-latex-chapters="true"] .latex-bibliography-heading { break-before: page"#))
        #expect(html.contains(#"body[data-latex-chapters="true"] h2.latex-part {"#))
        #expect(html.contains("& h2.latex-part::after { flex-grow: 2; }"))
    }

    @Test("入れ子の表はセルの行内に置き、題とリストは一緒に送る")
    func listingAndTableLayout() throws {
        let css = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" }).css
        #expect(
            css.contains(":is(td, th) table.latex-tabular { display: inline-table; vertical-align: top; margin: 0; }"))
        #expect(css.contains("figure.latex-listing { break-inside: avoid; page-break-inside: avoid; }"))
    }

    @Test("LaTeX のコードは指定した等幅書体を優先し、既定のタイプライターの太字・斜体を合成しない")
    func listingFont() throws {
        let css = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" }).css
        let selector = try #require(css.range(of: "\ncode, pre, .latex-url {", options: .backwards))
        let rule = css[selector.upperBound...].prefix { $0 != "}" }
        #expect(rule.contains(#"var(--latex-mono-font, "Surimono Computer Modern Typewriter")"#))
        #expect(rule.contains("font-synthesis: none;"))
    }

    @Test("memoir と KOMA の図にはクラスの自然長と明示した変更を適用する")
    func memoirCaptionLengths() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        func page(_ declaration: String, _ settings: String = "") -> String {
            let source = #"\documentclass\#(declaration)\#(settings)\begin{document}Text.\end{document}"#
            return HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
        }
        let memoir = page("{memoir}", #"\setlength{\belowcaptionskip}{4pt}"#)
        #expect(memoir.contains("--latex-abovecaptionskip: calc(6 * var(--tex-pt))"))
        #expect(memoir.contains("--latex-belowcaptionskip: calc(4 * var(--tex-pt"))
        let koma = page("{scrreprt}")
        #expect(koma.contains("--latex-intextsep: calc(12 * var(--tex-pt))"))
        #expect(koma.contains("--latex-abovecaptionskip: calc(10 * var(--tex-pt))"))
        #expect(koma.contains("--latex-belowcaptionskip: 0px"))
    }

    @Test("KOMA の小節番号の後ろを半角幅にする")
    func subsectionNumberGap() throws {
        let book = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let bookHTML = HTMLDocumentBuilder.build(
            fragment: LaTeXConverter.convert(
                #"\documentclass{scrbook}\begin{document}\subsection{Slot}\end{document}"#),
            format: .latex, theme: book)
        #expect(bookHTML.contains(#"data-latex-koma-heading="subsection" id="sec-"#))
        #expect(book.css.contains(#"[data-latex-koma-heading="subsection"] > .secnum { margin-inline-end: .5em; }"#))
    }

    @Test("議事録の初頁注は八ポイントの高さで小さい本文用書体の幅を確保する")
    func proceedingsTitleNoteWidth() throws {
        let article = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let notes = HTMLDocumentBuilder.build(
            fragment: LaTeXConverter.convert(
                #"\documentclass{amsproc}\title{Rail}\author{Fold Desk}\keywords{gauge}\begin{document}\maketitle\end{document}"#
            ), format: .latex, theme: article)
        #expect(notes.contains(#"<li id="fn-ams-title" style="list-style:none"><p class="latex-front-keywords">"#))
        #expect(
            article.css.contains(
                #"[data-latex-size="10"]:not([data-latex-local-main-font]) .footnotes #fn-ams-title > p"#))
        #expect(article.css.contains("inline-size: calc(100% / var(--ams-note-width-scale))"))
        #expect(article.css.contains("transform: scaleX(var(--ams-note-width-scale))"))
    }

    @Test("議事録の証明では数式上端の保護幅を所定の数式間隔に含める")
    func proceedingsDisplaySkip() throws {
        let article = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        #expect(article.css.contains("calc(.35 * var(--ams-linespacing) * var(--tex-pt) - .15em)"))
    }

    @Test("AMS 書籍の分類とキーワードと概要は表題の次の同じページに置く")
    func abstractPage() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let tex =
            #"\documentclass{amsbook}\begin{document}\keywords{Paper}\subjclass{01A}\begin{abstract}Folds\end{abstract}\maketitle\chapter{One}\end{document}"#
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(tex), format: .latex, theme: theme)
        #expect(
            html.contains(
                "<div class=\"latex-amsbook-verso\" data-latex-page-action=\"thispagestyle\" data-value=\"empty\">\n<p class=\"latex-front-classifications\"><em>2020 Mathematics Subject Classification.</em> 01A"
            ))
        #expect(html.contains("Paper</p>\n<div class=\"abstract latex-front-abstract\">"))
        #expect(html.contains(".latex-amsbook-verso > .abstract {\n    break-before: auto"))
    }

    @Test("LaTeX 専用の余白・書体・参照の導入後も他形式の HTML は同じバイト列になる")
    func otherFormats() {
        let theme = PrintTheme(id: "test", name: "Test", css: "body { color: black; }")
        // SHA-256 of each complete UTF-8 document at 35c0c6f, including the head and style sheets.
        // The Org baseline also includes the body class that suppresses theme numbering at every layer.
        let samples: [(DocumentFormat, HTMLFragment, String)] = [
            (
                .markdown, MarkdownConverter.convert("# Report\n\nFirst **line**.\n"),
                "01c5b27230f49034dc6b4474ae921383c141657ae3df81149ef9ceda706c48a8"
            ),
            (
                .org, OrgConverter.convert("#+TITLE: Report\n* Section\nFirst /line/.\n"),
                "f16fd7e1aefe08f5965afa352e05c5f9f888991d4f85af1d9944f44e793b5fb5"
            ),
            (
                .plainText, PlainTextConverter.convert("Report\nFirst line.\n"),
                "8a379abe2633c55762dc99b6f3fe3b434fe9ab8dd1d4384178d3d39a372a7e54"
            ),
            (
                .csv, CSVConverter.convert("Name,Value\nFirst,3\n"),
                "a3bef3f05442b2d0c5e6ac6ef13c3e19f9b00d40005102afc6632b89d1d75e9b"
            ),
        ]
        for (format, fragment, expected) in samples {
            let page = HTMLDocumentBuilder.build(fragment: fragment, format: format, theme: theme, language: "en")
            #expect(ContentHash.of(Data(page.utf8)).hex == expected, "\(format)")
        }
    }
}
