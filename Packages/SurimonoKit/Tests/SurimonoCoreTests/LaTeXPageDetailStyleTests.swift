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
        #expect(html.contains(#"<span class="secnum">Part I</span>Paper"#))
        #expect(html.contains(#"body[data-latex-chapters="true"] .latex-bibliography-heading { break-before: page"#))
        #expect(html.contains(#"body[data-latex-chapters="true"] h2.latex-part {"#))
        #expect(html.contains("text-align: center; padding-block-start: min(37vh, 28rem)"))
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
        // The common sheet has a rule with the same selector first; the LaTeX sheet's comes later and wins.
        let selector = try #require(css.range(of: "\ncode, pre {", options: .backwards))
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

    @Test("AMS 書籍の分類とキーワードと概要は表題の次の同じページに置く")
    func abstractPage() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let tex =
            #"\documentclass{amsbook}\begin{document}\keywords{Paper}\subjclass{01A}\begin{abstract}Folds\end{abstract}\maketitle\chapter{One}\end{document}"#
        let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(tex), format: .latex, theme: theme)
        #expect(html.contains("<div class=\"latex-amsbook-verso\">\n<p class=\"latex-front-classifications\">01A"))
        #expect(html.contains("Paper</p>\n<div class=\"abstract latex-front-abstract\">"))
        #expect(html.contains(".latex-amsbook-verso > .abstract {\n    break-before: auto"))
    }

    @Test("LaTeX 専用の余白・書体・参照の導入後も他形式の HTML は同じバイト列になる")
    func otherFormats() {
        let theme = PrintTheme(id: "test", name: "Test", css: "body { color: black; }")
        // SHA-256 of each complete UTF-8 document at 35c0c6f, including the head and style sheets.
        let samples: [(DocumentFormat, HTMLFragment, String)] = [
            (
                .markdown, MarkdownConverter.convert("# Report\n\nFirst **line**.\n"),
                "01c5b27230f49034dc6b4474ae921383c141657ae3df81149ef9ceda706c48a8"
            ),
            (
                .org, OrgConverter.convert("#+TITLE: Report\n* Section\nFirst /line/.\n"),
                "0ceb60ce4f1eb4e2996ad92ff6e7515137ae980016a78547c14a483f3d4ac209"
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
