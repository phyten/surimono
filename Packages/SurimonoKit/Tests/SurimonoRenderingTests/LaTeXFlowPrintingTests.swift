import AppKit
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFlowPrintingTests {
    @Test("二段の幅・段頭の図・段下の注と選択できる本文の順序を実際の PDF で確かめる", .timeLimit(.minutes(1)))
    func columns() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass[a4paper,twocolumn]{article}
                \usepackage[margin=20mm]{geometry}\setlength{\columnsep}{10pt}
                \begin{document}
                \noindent LEFTSTART\footnote{NOTEBOTTOM}\par
                \begin{figure}[t]\centering FLOATTOP\end{figure}
                \columnbreak\noindent RIGHTSTART\par
                \clearpage\noindent LASTPAGE\end{document}
                """#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let rendered = try await DocumentRenderer().prepare(source, settings: settings)
        let pdf = rendered.logicalDocument
        #expect(pdf.pageCount == 2)
        let page = try #require(pdf.page(at: 0))
        func rect(_ word: String) throws -> CGRect {
            let matches = pdf.findString(word, withOptions: [])
            try #require(matches.count == 1)
            let selection = try #require(matches.first)
            #expect(selection.pages.first == page)
            return selection.bounds(for: page)
        }
        let left = try rect("LEFTSTART")
        let right = try rect("RIGHTSTART")
        let note = try rect("NOTEBOTTOM")
        let figure = try rect("FLOATTOP")
        let textWidth = page.bounds(for: .mediaBox).width - 2 * 20 * 72 / 25.4
        #expect(abs(right.minX - left.minX - (textWidth + 10 * 72 / 72.27) / 2) < 3)
        #expect(abs(left.midY - figure.midY) < 5)
        #expect(figure.midY > right.midY && figure.minX > right.minX)
        #expect(note.minX < right.minX && abs(note.minY - 20 * 72 / 25.4) < 8)
        let text = try #require(page.string)
        let words = text.components(separatedBy: .whitespacesAndNewlines).joined()
        let ordered = try #require(words.range(of: "LEFTSTART.*FLOATTOP.*RIGHTSTART", options: .regularExpression))
        #expect(!words[ordered].isEmpty)
        #expect(pdf.page(at: 1)?.string?.contains("LASTPAGE") == true)
    }

    @Test("段とページをまたぐ一段落の単語を、一語ずつ元の順に選択できる", .timeLimit(.minutes(1)))
    func readingOrder() async throws {
        let tokens = (0..<320).map { String(format: "word%03d", $0) }
        let html =
            "<style>body{font:12px/18px monospace}p{margin:0}</style>"
            + "<template data-latex-columns=\"2\" data-latex-rule=\"0\"></template><p>" + tokens.joined(separator: " ")
            + "</p>"
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 310, height: 200),
            margins: .uniform(millimeters: 5), allowsJavaScript: false, latexFlow: true)
        #expect(result.issues.isEmpty)
        #expect(result.document.pageCount > 1)
        let text = try #require(result.document.string)
        #expect(text.matches(of: /word[0-9]{3}/).map { String($0.output) } == tokens)
    }

    @Test("脚注が用紙より長い場合は元の本文と注を一段で刷り、確認に理由を出す", .timeLimit(.minutes(1)))
    func fallback() async throws {
        let html =
            "<p>BODY<sup class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup></p>"
            + "<section class=\"footnotes\"><ol><li id=\"fn-1\"><div style=\"height:400px\">LONGNOTE</div></li></ol></section>"
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 310, height: 200),
            margins: .uniform(millimeters: 5), allowsJavaScript: false, latexFlow: true)
        #expect(result.issues.contains { $0.id == "latex-flow-fallback" })
        #expect(result.document.string?.contains("LONGNOTE") == true)
        #expect(result.document.string?.contains("BODY") == true)
    }

    @Test("十二ページの二段論文と百ページの脚注付き本文を計時する", .timeLimit(.minutes(1)), arguments: [12, 100])
    func timing(count: Int) async throws {
        let columns = count == 12 ? "[twocolumn]" : ""
        let line = String(repeating: "A paragraph for measuring the column width and the selectable text. ", count: 8)
        let pages = (1...count).map { i in
            "Section \(i). \(line)\\footnote{Note \(i).}\\par " + (count == 12 ? "\\columnbreak " : "") + line
        }
        let source =
            "\\documentclass\(columns){article}\\begin{document}" + pages.joined(separator: "\\clearpage ")
            + "\\end{document}"
        let fragment = LaTeXConverter.convert(source)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        let start = ContinuousClock.now
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PaperSize.a4.size,
            margins: .uniform(millimeters: 20), allowsJavaScript: false, latexFlow: true)
        let elapsed = start.duration(to: .now)
        #expect(result.issues.isEmpty)
        #expect(result.document.pageCount == count)
        // Wall-clock budgets with room for a shared CI runner, which took 4.8 s where a desk Mac takes 1.5 s.
        // They catch a layout that stopped being linear, not a slow machine.
        #expect(elapsed < .seconds(count == 12 ? 12 : 60), "組版時間 \(elapsed)")
    }
}
