import Foundation
import SurimonoCore
import Testing

struct TypefaceTests {
    @Test("書体は文書ごとに往復し、以前の記録には書体の指定がない")
    func records() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(DocumentSettings.self, from: Data(#"{"textScale":1.25}"#.utf8))
        #expect(old.typeface == nil && old.textScale == 1.25)
        for face in Typeface.allCases {
            let settings = DocumentSettings(typeface: face)
            #expect(try decoder.decode(DocumentSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test("設定セットはスタイルに書体を含め、テーマのない形式では外す")
    func settingSet() throws {
        let settings = DocumentSettings(textScale: 1, typeface: .latex)
        let set = PrintSettingSet(name: "Example", settings: settings)
        #expect(set.parts == [.style])
        #expect(set.keeping([.style]).typeface == .latex)
        #expect(set.keeping([]).typeface == nil)
        #expect(set.applicable(to: .pdf, themeIDs: [], presetIDs: []).typeface == nil)
        #expect(set.matches(settings))
        #expect(!set.matches(DocumentSettings(textScale: 1)))
        #expect(PrintSettingSet(name: "Default", settings: DocumentSettings(textScale: 1)).typeface == .style)
        #expect(try JSONDecoder().decode(PrintSettingSet.self, from: JSONEncoder().encode(set)) == set)
    }

    @Test("欧文の書体だけを先頭に置き、テーマの言語別の書体と優先順位を保つ")
    func css() {
        let theme = PrintTheme(
            id: "user", name: "User",
            css: """
                @font-face { font-family: 'My Face'; src:local('My Face'); }
                body, th { font-family: "Hiragino Sans", serif !important; }
                @media print { pre { font: 500 1em/1.4 var(--code, monospace); } }
                """)
        let css = HTMLDocumentBuilder.styleSheet(theme: theme, textScale: 1.5, typeface: .latex, language: "ko")
        #expect(
            css.contains(
                #"--surimono-style-family: "Apple SD Gothic Neo", "Hiragino Sans", serif !important"#))
        #expect(
            css.contains(
                "font: 500 1em/1.4 var(--surimono-western) var(--surimono-style-family, serif); --surimono-style-family: var(--code, monospace)"
            ))
        #expect(css.contains("@font-face { font-family: 'My Face'"))
        #expect(css.contains(#"--surimono-western: "Surimono Computer Modern""#))
        #expect(css.contains(#"--surimono-western: "Surimono Computer Modern Typewriter""#))
        #expect(css.components(separatedBy: "data:font/ttf;base64,").count == 6)
        #expect(css.contains("html { zoom: 1.5; }"))
        #expect(!HTMLDocumentBuilder.styleSheet(theme: theme).contains("data:font/ttf"))
    }

    @Test("独自の変数でフォントを一括指定したスタイルも元の字の大きさと書体候補を残す")
    func shorthandVariable() {
        let theme = PrintTheme(
            id: "user", name: "User",
            css: """
                :root { --reading: italic 12pt/1.5 Georgia, "YuMincho", serif; }
                @media print { :root { --reading: 11pt Charter, serif } }
                body { font: var(--reading) !important }
                pre { font: inherit; }
                """)
        let css = HTMLDocumentBuilder.styleSheet(theme: theme, typeface: .latex)
        #expect(css.contains(#"--surimono-family--reading: Georgia, "YuMincho", serif"#))
        #expect(css.contains("--surimono-family--reading: Charter, serif"))
        #expect(css.contains("font: var(--reading) !important"))
        #expect(css.contains("--surimono-style-family: var(--surimono-family--reading, serif) !important"))
        #expect(css.contains("pre { font: inherit; font-family: var(--surimono-western)"))
    }

    @Test("LaTeX の各スタイル・縦書き・テーマのない形式では書体を重ねない")
    func availability() throws {
        let excluded = ["latex", "latex-article", "latex-report", "latex-plain-ja", "tategaki"]
        for theme in try PrintThemeLibrary.load() {
            let enabled = !excluded.contains(theme.id)
            #expect(Typeface.isAvailable(themeID: theme.id, usesPrintTheme: true) == enabled)
            let standard = HTMLDocumentBuilder.styleSheet(theme: theme)
            let latex = HTMLDocumentBuilder.styleSheet(theme: theme, typeface: .latex)
            #expect((standard != latex) == enabled, "\(theme.id)")
        }
        for format in DocumentFormat.allCases {
            #expect(
                Typeface.isAvailable(themeID: "standard", usesPrintTheme: format.usesPrintTheme)
                    == format.usesPrintTheme)
        }
    }
}
