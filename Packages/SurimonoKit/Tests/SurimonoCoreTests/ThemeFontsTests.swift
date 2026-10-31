import Foundation
import SurimonoCore
import Testing

struct ThemeFontsTests {
    @Test("LaTeX 風のテーマだけが、同梱の Computer Modern の書体をスタイルに埋め込む")
    func onlyTheLaTeXThemeEmbedsFonts() throws {
        for theme in try PrintThemeLibrary.load() {
            let css = HTMLDocumentBuilder.styleSheet(theme: theme)
            #expect(css.contains("@font-face") == (theme.id == "latex"), "\(theme.id)")
        }
        let latex = try #require(PrintThemeLibrary.load().first { $0.id == "latex" })
        let css = HTMLDocumentBuilder.styleSheet(theme: latex)
        #expect(css.components(separatedBy: "font-family: \"Surimono Computer Modern\";").count == 5)
        #expect(css.contains("font-family: \"Surimono Computer Modern\"; font-weight: bold; font-style: italic;"))
        #expect(css.components(separatedBy: "font-family: \"Surimono Computer Modern Typewriter\";").count == 2)
        #expect(css.contains("src: url(\"data:font/ttf;base64,"))
    }

    @Test("書体は欧文の範囲だけに使い、和文と … や矢印は次の書体に任せる")
    func fontsCoverLatinOnly() {
        let css = ThemeFonts.faces(forStyleSheet: "body { font-family: \"Surimono Computer Modern\", serif; }")
        #expect(css.contains("unicode-range: U+0020-007E, U+00A0-00FF,"))
        #expect(!css.contains("2026"))
        #expect(!css.contains("2190"))
    }

    @Test("ユーザーの CSS も名前を引用符で書けば同じ書体を使え、等幅だけなら等幅だけを埋め込む")
    func userStyleSheetsNameTheFamilies() {
        let typewriter = ThemeFonts.faces(forStyleSheet: "code { font-family: 'Surimono Computer Modern Typewriter'; }")
        #expect(typewriter.components(separatedBy: "@font-face").count == 2)
        #expect(typewriter.contains("\"Surimono Computer Modern Typewriter\""))
        #expect(ThemeFonts.faces(forStyleSheet: "body { font-family: serif; }").isEmpty)
    }
}
