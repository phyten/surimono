import SurimonoCore
import Testing

struct LaTeXSocietyLayoutTests {
    @Test("和文誌の二桁の文献番号を一つの改行禁止ラベルに置く")
    func bibliographyLabel() throws {
        let source = #"""
            \documentclass[submit]{ipsj}
            \begin{document}\begin{thebibliography}{99}
            \bibitem[12]{reference}文献本文。
            \end{thebibliography}\end{document}
            """#
        let fragment = LaTeXConverter.convert(source)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-plain-ja" })
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
        #expect(html.contains(#"<span class="bib-label">[12]</span>"#))
        let rule = try #require(html.components(separatedBy: "& .latex-bibliography .bib-label {").dropFirst().first)
        #expect(rule.prefix(while: { $0 != "}" }).contains("white-space: nowrap"))
    }

    @Test("学会の版型を初期用紙に選び、組版の属性に渡す")
    func trim() throws {
        for (name, layout) in [("ipsj", PrintLayout.a4Single), ("ieicej", .b5Single), ("ieice", .journalSingle)] {
            let fragment = LaTeXConverter.convert("\\documentclass{\(name)}\\begin{document}Body.\\end{document}")
            let info = try #require(fragment.latexClass)
            #expect(PrintLayout.defaultLaTeXLayout(for: info) == layout)
            let theme = try #require(
                PrintThemeLibrary.load().first { $0.id == PrintThemeLibrary.defaultLaTeXStyle(for: info) })
            let html = HTMLDocumentBuilder.build(fragment: fragment, format: .latex, theme: theme)
            let body = try #require(html.components(separatedBy: "<body ").last?.split(separator: ">").first)
            #expect(body.contains("data-latex-publication-grid"))
            #expect(body.contains("data-latex-class=\"\(name)\""))
        }
        #expect(
            PrintLayout.defaultLaTeXLayout(for: LaTeXConverter.documentClassInfo("\\documentclass{article}")) == nil)
    }
}
