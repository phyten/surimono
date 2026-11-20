import SurimonoCore
import SurimonoFormats
import Testing

struct LaTeXStylePackageAttributeTests {
    @Test("学会スタイルとモードの属性を記事クラスと併記する")
    func attributes() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        for (preamble, family, mode) in [
            (#"\usepackage{neurips_2026}"#, "neurips", "submission"),
            (#"\usepackage{iclr2027_conference,times}\iclrfinalcopy"#, "iclr", "final"),
        ] {
            let source = #"\documentclass{article}"# + preamble + #"\begin{document}Body.\end{document}"#
            let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
            let body = try #require(html.components(separatedBy: "<body ").last)
            #expect(body.contains(#"data-latex-class="article""#))
            #expect(body.contains("data-latex-style=\"\(family)\""))
            #expect(body.contains("data-latex-style-mode=\"\(mode)\""))
        }
    }
}
