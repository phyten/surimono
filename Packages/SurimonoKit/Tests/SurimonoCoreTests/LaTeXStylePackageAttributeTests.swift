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
            (#"\usepackage{icml2026}"#, "icml", "submission"),
            (#"\usepackage[accepted]{icml2026}"#, "icml", "final"),
            (#"\usepackage[review]{cvpr}"#, "cvpr", "submission"),
            (#"\usepackage{cvpr}"#, "cvpr", "final"),
            (#"\usepackage[review]{acl}"#, "acl", "submission"),
            (#"\usepackage{acl}"#, "acl", "final"),
            (#"\usepackage[submission]{aaai2027}"#, "aaai", "submission"),
            (#"\usepackage{aaai2027}"#, "aaai", "final"),
        ] {
            let source = #"\documentclass{article}"# + preamble + #"\begin{document}Body.\end{document}"#
            let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
            let body = try #require(html.components(separatedBy: "<body ").last)
            #expect(body.contains(#"data-latex-class="article""#))
            #expect(body.contains("data-latex-style=\"\(family)\""))
            #expect(body.contains("data-latex-style-mode=\"\(mode)\""))
        }
    }

    @Test("本文の空きと段末の明示指定を組版の属性へ渡す")
    func spacingPreferences() throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        for (commands, french, ragged) in [
            (#"\usepackage{aaai2027}"#, true, false),
            (#"\usepackage{icml2026}\raggedbottom"#, false, true),
            (#"\usepackage{acl}\frenchspacing\raggedbottom\flushbottom"#, true, false),
        ] {
            let source = #"\documentclass{article}"# + commands + #"\begin{document}Body.\end{document}"#
            let html = HTMLDocumentBuilder.build(fragment: LaTeXConverter.convert(source), format: .latex, theme: theme)
            let tag = try #require(html.components(separatedBy: "<body ").last?.split(separator: ">").first)
            #expect(tag.contains("data-latex-french-spacing") == french)
            #expect(tag.contains("data-latex-ragged-bottom") == ragged)
        }
    }

}
