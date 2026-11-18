import Foundation
import Testing

@testable import SurimonoCore

struct ComputationalMarkdownTests {
    @Test(
        "実行用のフェンスだけで貼り付け形式を識別する",
        arguments: [
            ("```{python}\nx\n```", ClipboardTextKind.quarto),
            ("---\noutput: pdf_document\n---\n```{r}\nx\n```", .rMarkdown),
            ("```{r, echo=FALSE}\nx\n```", .rMarkdown),
            ("---\nformat: pdf\n---\n```{r, echo=FALSE}\nx\n```", .quarto),
            ("```{r, echo=FALSE}\n#| label: x\nx\n```", .quarto),
            ("# Paper\n\n```r\nx\n```", .markdown),
            ("# Paper\n\n````md\n```{r}\nx\n```\n````", .markdown),
        ])
    func clipboard(source: String, expected: ClipboardTextKind) {
        #expect(ClipboardFormatDetector.detect(source).action == .open(expected))
    }

    @Test("配布する見本を印刷用HTMLにして参照と未実行の注記を確認する", arguments: ["qmd", "Rmd"])
    func sample(suffix: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Samples/sample." + suffix), encoding: .utf8)
        let fragment = ComputationalMarkdown.convert(source)
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        let format = try #require(DocumentFormat(fileExtension: suffix))
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: format, theme: theme)
        #expect(
            html.contains(
                suffix == "qmd" ? "body class=\"surimono format-quarto\"" : "body class=\"surimono format-rmarkdown\""))
        #expect(html.contains("default-src 'none'"))
        #expect(fragment.body.contains("chunk-result-note"))
        #expect(fragment.body.contains(suffix == "qmd" ? "href=\"#fig-count\"" : "href=\"#fig:widths\""))
        #expect(fragment.body.contains(suffix == "qmd" ? "mermaid-block" : "language-r hl"))
        #expect(!fragment.body.contains("opts_chunk"))
    }
}
