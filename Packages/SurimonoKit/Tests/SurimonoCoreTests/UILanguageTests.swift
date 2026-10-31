import Foundation
import Testing

@testable import SurimonoCore

struct UILanguageTests {
    private let languages = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"]

    @Test("組み込みの全テーマ・カテゴリー・プリセットは8言語の名前を持つ")
    func names() throws {
        let themes = try PrintThemeLibrary.load()
        let categories = try PrintThemeLibrary.categories()
        let presets = try HTMLCleanupPresetLibrary.load().presets
        #expect(themes.count == 95)
        #expect(categories.count == 12)
        #expect(presets.count == 4)
        for names in themes.map(\.localizedNames) + categories.map(\.localizedNames) + presets.map(\.localizedNames) {
            for language in languages {
                #expect(names[language]?.isEmpty == false, "Missing name: \(language)")
            }
        }
    }

    @Test("全印刷レイアウトは8言語の名前を持ち地域指定でも同じ名前になる")
    func layouts() {
        for layout in PrintLayout.presets {
            for language in languages {
                #expect(!layout.displayName(language: language).isEmpty)
                #expect(layout.displayName(language: language + "-CA") == layout.displayName(language: language))
                if language != "en" {
                    #expect(layout.displayName(language: language) != layout.displayName(language: "en"))
                }
            }
        }
        #expect(PrintLayout.a4Single.displayName(language: "de") == "A4 Einseitig")
        #expect(PrintLayout.a4Duplex.displayName(language: "zh-Hant") == "A4 雙面")
        #expect(PrintLayout.a3BookletA4.displayName(language: "fr") == "A3 Livret → A4")
    }

    @Test("名前は完全一致・基底言語・英語の順で選ぶ")
    func fallback() {
        let names = ["fr-CA": "Canada", "fr": "France", "en": "English", "zh-Hans": "简体", "zh": "中文"]
        #expect(UILanguage.name(names, language: "fr-CA", english: "Fallback") == "Canada")
        #expect(UILanguage.name(names, language: "fr-BE", english: "Fallback") == "France")
        #expect(UILanguage.name(names, language: "pt-BR", english: "Fallback") == "English")
        #expect(UILanguage.name(names, language: "zh-Hant", english: "Fallback") == "English")
        #expect(UILanguage.name(names, language: "zh-Hant-TW", english: "Fallback") == "English")
        #expect(UILanguage.name(names, language: "zh-Hans-CN", english: "Fallback") == "简体")
        #expect(UILanguage.name([:], language: "de", english: "User Style") == "User Style")
        #expect(UILanguage.name(["fr": ""], language: "fr", english: "Fallback") == "Fallback")
    }

    @Test("テーマ・カテゴリー・プリセットで中国語の文字体系を混ぜない")
    func consumers() {
        let names = ["zh-Hans": "简体", "fr": "Français"]
        let theme = PrintTheme(id: "test", name: "English", localizedNames: names, css: "")
        let category = PrintThemeCategory(id: "test", name: "English", localizedNames: names)
        let preset = HTMLCleanupPreset(id: "test", name: "English", localizedNames: names)
        #expect(theme.displayName(language: "zh-Hant") == "English")
        #expect(category.displayName(language: "zh-Hant") == "English")
        #expect(preset.displayName(language: "zh-Hant") == "English")
        #expect(theme.displayName(language: "fr-CA") == "Français")
        #expect(category.displayName(language: "fr-CA") == "Français")
        #expect(preset.displayName(language: "fr-CA") == "Français")
    }

    @Test("従来のja付き目録と利用者のプリセットを読める")
    func legacy() throws {
        let data = Data(
            #"{"categories":[{"id":"a","name":"A","ja":"分類"}],"featured":[],"themes":[{"id":"t","name":"T","ja":"題","category":"a"}]}"#
                .utf8)
        let catalog = try PrintThemeLibrary.catalog(from: data)
        #expect(catalog.categories.first?.ja == "分類")
        #expect(catalog.themes.first?.ja == "題")
        let preset = try JSONDecoder().decode(
            HTMLCleanupPreset.self,
            from: Data(
                #"{"id":"user","name":"User","localizedNames":{"ja":"利用者"},"removeSelectors":["nav"],"keepSelectors":[],"extraCSS":"p{color:black}","disablesJavaScript":true}"#
                    .utf8))
        #expect(preset.displayName(language: "ja") == "利用者")
        #expect(preset.displayName(language: "de") == "User")
        #expect(preset.removeSelectors == ["nav"])
        #expect(preset.disablesJavaScript)
        #expect(try JSONDecoder().decode(HTMLCleanupPreset.self, from: JSONEncoder().encode(preset)) == preset)
    }

    @Test("名前だけの利用者プリセットと旧jaキーを読める")
    func minimalPreset() throws {
        let preset = try JSONDecoder().decode(
            HTMLCleanupPreset.self, from: Data(#"{"id":"custom","name":"Custom","ja":"自作"}"#.utf8))
        #expect(preset.displayName(language: "ja") == "自作")
        #expect(preset.displayName(language: "es") == "Custom")
        #expect(preset.removeSelectors.isEmpty)
        #expect(!preset.disablesJavaScript)
    }

    @Test("言語名は現在の言語名と自称を並べ同じなら一度だけ表示する")
    func labels() {
        #expect(UILanguage.label(for: "en", in: "ja") == "英語 English")
        #expect(UILanguage.label(for: "ja", in: "ja") == "日本語")
        for language in languages {
            let native = Locale(identifier: language).localizedString(forIdentifier: language)
            #expect(UILanguage.label(for: language, in: language) == native)
            let translated = Locale(identifier: "ja").localizedString(forIdentifier: language) ?? language
            if language != "ja" {
                #expect(UILanguage.label(for: language, in: "ja") == "\(translated) \(native ?? language)")
            }
        }
        #expect(UILanguage.label(for: "zh-Hans", in: "ja") != UILanguage.label(for: "zh-Hant", in: "ja"))
    }
}
