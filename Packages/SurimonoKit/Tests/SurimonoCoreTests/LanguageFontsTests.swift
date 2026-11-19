import Foundation
import Testing

@testable import SurimonoCore

struct LanguageFontsTests {
    @Test("変更不要な言語はバイトを変えない", arguments: ["ja", "en", "ar"])
    func unchanged(language: String) {
        let css = "p { font-family: \"Hiragino Sans\", sans-serif; }"
        #expect(LanguageFonts.adapt(css, language: language) == css)
    }

    @Test("書体の種類に合わせて最初の和文書体の前に挿入する")
    func families() {
        let css = "p { font-family: \"Helvetica Neue\", \"Hiragino Sans\", sans-serif; }"
        #expect(
            LanguageFonts.adapt(css, language: "zh-Hans")
                == "p { font-family: \"Helvetica Neue\", \"PingFang SC\", \"Hiragino Sans\", sans-serif; }")
        #expect(
            LanguageFonts.adapt("p{font-family:'Hiragino Mincho ProN',serif}", language: "zh-Hans")
                == "p{font-family:\"Songti SC\", 'Hiragino Mincho ProN',serif}")
        #expect(LanguageFonts.adapt(css, language: "ko").contains("\"Apple SD Gothic Neo\", \"Hiragino Sans\""))
        #expect(LanguageFonts.adapt(css, language: "ru") == css)
        #expect(
            LanguageFonts.adapt("p{--body:YuMincho,serif;font:12pt Osaka-Mono,monospace}", language: "ru")
                == "p{--body:\"Times New Roman\", YuMincho,serif;font:12pt \"Menlo\", Osaka-Mono,monospace}")
    }

    @Test("URLと書体定義と本文文字列とコメントを変更しない")
    func opaque() {
        let css =
            "/* Hiragino Sans */ @font-face{font-family:'Hiragino Sans';src:url(data:font/woff;base64,HiraginoSans)} p{content:'Hiragino Sans';background:url('Hiragino Sans');}"
        #expect(LanguageFonts.adapt(css, language: "zh-Hans") == css)
    }

    @Test("HTMLの言語と方向とスタイルを揃える")
    func builder() {
        let theme = PrintTheme(id: "test", name: "Test", css: "p{font-family:'Hiragino Sans'}")
        func build(_ body: String, language: String? = nil) -> String {
            HTMLDocumentBuilder.build(
                fragment: HTMLFragment(body: body, language: language), format: .markdown, theme: theme)
        }
        #expect(build("本文です").contains("<html lang=\"ja\">"))
        #expect(HTMLDocumentBuilder.styleSheet(theme: theme, language: "ja") == theme.css)
        #expect(build("本文です", language: "en").contains("<html lang=\"en\">"))
        #expect(build("这是一座虚构的图书馆，每天早上都会开放。读者可以在这里阅读书籍，学习新的知识，并且记录自己的生活经验。").contains("<html lang=\"zh-Hans\">"))
        #expect(build("", language: "zh").contains("<html lang=\"zh-Hans\">"))
        #expect(build("مرحبا بكم في المكتبة الجديدة").contains("<html lang=\"ar\" dir=\"rtl\">"))
    }
}

extension LanguageFontsTests {
    @Test("全テーマの和文書体には中国語書体が先行する")
    func catalog() throws {
        let nonJapanese: Set<String> = [
            "Marker Felt", "STIX Two Text", "SFMono-Regular", "inherit", "Avenir Next Condensed", "serif", "sans-serif",
            "monospace", "cursive", "fantasy", "system-ui", "-apple-system", "BlinkMacSystemFont", "Helvetica Neue",
            "Helvetica", "Arial", "Times New Roman", "Times", "Georgia", "Palatino", "Baskerville", "Didot",
            "Hoefler Text", "Avenir Next", "Avenir", "Optima", "Futura", "Gill Sans", "Trebuchet MS", "Verdana",
            "Tahoma", "Menlo", "Monaco", "Courier New", "Courier", "American Typewriter", "Noteworthy", "Chalkboard SE",
            "Chalkboard", "Chalkduster", "Bradley Hand", "Comic Sans MS", "Snell Roundhand", "Apple Chancery",
            "Papyrus", "Copperplate", "Impact", "DIN Alternate", "DIN Condensed", "Rockwell", "Charter",
            "Iowan Old Style", "Savoye LET", "Academy Engraved LET", "Surimono Computer Modern",
            "Surimono Computer Modern Typewriter", "PT Serif", "Geeza Pro", "Arial Hebrew",
            "Songti TC", "STSong", "LiSong Pro", "PingFang TC", "AppleMyungjo", "Apple SD Gothic Neo",
        ]
        let chinese: Set<String> = ["PingFang SC", "Songti SC", "Yuanti SC", "Kaiti SC"]
        let pattern = /(?:font-family|--tex-(?:serif|sans|body-fonts|sans-fonts))\s*:\s*([^;}]+)/
        // Inspect the literal fallback names, including nested var() fallbacks. The
        // custom properties containing the actual font lists are inspected above as well.
        func literalFamilies(_ value: Substring) -> [Substring] {
            var list = String(value)
            let variable = /var\(--[\w-]+(?:,\s*([^()]+))?\)/
            while list.contains(variable) { list = list.replacing(variable) { String($0.1 ?? "") } }
            return list.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        for theme in try PrintThemeLibrary.load() {
            for match in theme.css.matches(of: pattern) {
                for raw in literalFamilies(match.1) {
                    let family = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"'"))
                    if !nonJapanese.contains(family), !chinese.contains(family) {
                        let isolated = "p{font-family:\"\(family)\"}"
                        #expect(
                            LanguageFonts.adapt(isolated, language: "zh-Hans") != isolated, "\(theme.id): \(family)")
                    }
                }
            }
            let adapted = LanguageFonts.adapt(theme.css, language: "zh-Hans")
            for match in adapted.matches(of: pattern) {
                var hasChinese = false
                for raw in literalFamilies(match.1) {
                    let family = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"'"))
                    if chinese.contains(family) {
                        hasChinese = true
                    } else if !nonJapanese.contains(family) {
                        #expect(
                            hasChinese,
                            "\(theme.id): \(family) needs classification or an explicit non-Japanese exemption")
                    }
                }
            }
            #expect(LanguageFonts.adapt(adapted, language: "zh-Hans") == adapted)
        }
    }

    @Test("大きいデータURLを含むCSSも変更箇所以外を保持する", .timeLimit(.minutes(1)))
    func largeCSS() {
        let url = "a{background:url(data:image/svg+xml;base64," + String(repeating: "a", count: 300_000) + ")}"
        #expect(
            LanguageFonts.adapt(url + "p{font-family:hiragino sans,sans-serif}", language: "zh-Hans") == url
                + "p{font-family:\"PingFang SC\", hiragino sans,sans-serif}")
    }
}

extension LanguageFontsTests {
    @Test("文字列の区切り記号で宣言や書体定義を分割しない")
    func stringDelimiters() {
        let css = "p{content:'}';font-family:'Hiragino Sans'} @font-face{font-family:'Hiragino Sans';src:url('x')}"
        #expect(
            LanguageFonts.adapt(css, language: "zh-Hans")
                == "p{content:'}';font-family:\"PingFang SC\", 'Hiragino Sans'} @font-face{font-family:'Hiragino Sans';src:url('x')}"
        )
    }

    @Test(
        "丸ゴシックと教科書体と等幅と明朝を対応づける",
        arguments: [
            ("Tsukushi B Round Gothic", "zh-Hant", "Yuanti TC"),
            ("Klee", "zh-Hans", "Kaiti SC"),
            ("Osaka-Mono", "ru", "Menlo"),
            ("Yu Mincho", "ko", "AppleMyungjo"),
            ("Toppan Bunkyu Gothic", "zh-Hans", "PingFang SC"),
            ("YuMincho", "el", "Times New Roman"),
        ])
    func classes(family: String, language: String, expected: String) {
        #expect(
            LanguageFonts.adapt("p{font-family:'\(family)'}", language: language)
                == "p{font-family:\"\(expected)\", '\(family)'}")
    }
}

extension LanguageFontsTests {
    @Test("書体の短縮宣言でも先行する代替書体を重複させない")
    func shorthandDuplicate() {
        let css = "p{font:italic 12pt/1.5 'Helvetica Neue','Hiragino Sans',sans-serif}"
        #expect(LanguageFonts.adapt(css, language: "ru") == css)
    }
}
