import SurimonoCore
import Testing

struct LaTeXJournalTypesettingTests {
    @Test("学会誌の印刷スタイルを選択し、APS プレプリントの基本行送りは PDF で 21.6 ポイントになる")
    func classTypography() throws {
        let themes = try PrintThemeLibrary.load()
        let theme = try #require(themes.first { $0.id == "latex-article" })
        for (declaration, name) in [
            ("[conference]{IEEEtran}", "ieee"), ("[aps,preprint]{revtex4-2}", "aps-preprint"),
            ("[aps,reprint]{revtex4-2}", "aps"), ("{llncs}", "lncs"), ("[preprint]{elsarticle}", "elsevier"),
        ] {
            let paper = LaTeXConverter.convert(#"\documentclass\#(declaration)\begin{document}Body\end{document}"#)
            let html = HTMLDocumentBuilder.build(fragment: paper, format: .latex, theme: theme)
            #expect(html.components(separatedBy: "<body").last?.contains("data-latex-journal=\"\(name)\"") == true)
        }
        #expect(theme.css.contains(#"body[data-latex-journal="aps-preprint"] { --tex-baseline: 27px; }"#))
        #expect(
            theme.css.contains(
                #"body[data-latex-journal="ieee"] .latex-bibliography { font-size: calc(8 * var(--tex-pt))"#))
        #expect(theme.css.contains("margin-inline: calc(28.453 * var(--tex-pt))"))
        #expect(theme.css.contains("--latex-ieee-footnote-baseline: 9;"))
        #expect(theme.css.contains("--latex-ieee-footnote-baseline: 10.5;"))
        #expect(theme.css.contains("--latex-array-baseline: var(--latex-ieee-footnote-baseline)"))
        #expect(theme.css.contains(#"figure table { --latex-array-baseline: 11;"#))
        #expect(theme.css.contains("padding-inline: calc(2 * var(--tex-pt))"))
        let paper = LaTeXConverter.convert(#"\documentclass{article}\begin{document}Body\end{document}"#)
        let html = HTMLDocumentBuilder.build(fragment: paper, format: .latex, theme: theme)
        #expect(html.components(separatedBy: "<body").last?.contains("data-latex-journal") == false)
        #expect(themes.filter { !$0.id.hasPrefix("latex-") }.allSatisfy { !$0.css.contains("data-latex-journal") })
    }
}
