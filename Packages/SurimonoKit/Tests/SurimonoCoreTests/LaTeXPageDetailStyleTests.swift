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
        #expect(css.contains("font-family: var(--latex-mono-font, Menlo), Menlo, monospace;"))
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
