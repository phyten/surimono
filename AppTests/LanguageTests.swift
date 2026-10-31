import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct LanguageTests {
    @Test("言語指定はAppleLanguagesに保存しシステムに戻すと削除する")
    func persistence() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.setPersistentDomain(["unrelatedSetting": "preserve"], forName: suite.name)
        let preferences = AppPreferences(defaults: suite.defaults, domainName: suite.name)
        #expect(preferences.languageOverride == nil)
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
            preferences.languageOverride = language
            #expect(suite.defaults.persistentDomain(forName: suite.name)?["AppleLanguages"] as? [String] == [language])
            #expect(AppPreferences(defaults: suite.defaults, domainName: suite.name).languageOverride == language)
        }
        preferences.languageOverride = nil
        #expect(suite.defaults.persistentDomain(forName: suite.name)?["AppleLanguages"] == nil)
        #expect(suite.defaults.persistentDomain(forName: suite.name)?["unrelatedSetting"] as? String == "preserve")
        #expect(AppPreferences(defaults: suite.defaults, domainName: suite.name).languageOverride == nil)
    }

    @Test("共有や起動引数の言語をアプリに保存された指定と取り違えない")
    func inheritedLanguage() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.register(defaults: ["AppleLanguages": ["de"]])
        // The search list may return this Mac's global languages instead of the registered fallback.
        // Neither belongs to the application's saved choice.
        #expect(defaults.persistentDomain(forName: suite.name)?["AppleLanguages"] == nil)
        #expect(AppPreferences(defaults: defaults, domainName: suite.name).languageOverride == nil)
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(["AppleLanguages": ["fr"]], forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        #expect(defaults.persistentDomain(forName: suite.name)?["AppleLanguages"] == nil)
        #expect(AppPreferences(defaults: defaults, domainName: suite.name).languageOverride == nil)
    }

    @Test("macOSで地域つき言語を指定しても対応する選択肢を表示する")
    func regionalOverride() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.setPersistentDomain(["AppleLanguages": ["fr-CA"]], forName: suite.name)
        #expect(AppPreferences(defaults: suite.defaults, domainName: suite.name).languageOverride == "fr")
        suite.defaults.setPersistentDomain(["AppleLanguages": ["zh-Hant-TW"]], forName: suite.name)
        #expect(AppPreferences(defaults: suite.defaults, domainName: suite.name).languageOverride == "zh-Hant")
    }

    @Test("ビルド済みアプリに8言語の翻訳リソースが含まれる")
    func builtLocalizations() throws {
        for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
            #expect(Bundle.main.localizations.contains(language))
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            #expect(bundle.localizedString(forKey: "Language", value: "MISSING", table: nil) != "MISSING")
        }
    }

    @Test("文字列カタログの全キーに8言語の翻訳済みエントリがある")
    func catalogCoverage() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: source))
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
                let translation = try #require(entry.localizations[language], "\(key): \(language)")
                let units = translation.units
                #expect(!units.isEmpty, "\(key): \(language)")
                for unit in units {
                    #expect(unit.state == "translated", "\(key): \(language)")
                    #expect(!unit.value.isEmpty, "\(key): \(language)")
                }
                for value in translation.expandedValues {
                    #expect(specifiers(value) == specifiers(key), "\(key): \(language)")
                }
            }
        }
    }

    private func specifiers(_ text: String) -> [String] {
        let pattern = #/%(?:(\d+)\$)?(lld|ld|@)/#
        return text.matches(of: pattern).enumerated().map { index, match in
            let position = match.output.1.map(String.init) ?? String(index + 1)
            return "\(position):\(match.output.2)"
        }.sorted()
    }

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }
    private struct Entry: Decodable { let localizations: [String: Translation] }
    private struct Unit: Decodable {
        let state: String
        let value: String
    }
    private struct Translation: Decodable {
        let stringUnit: Unit?
        let variations: [String: [String: Translation]]?
        let substitutions: [String: Substitution]?
        var units: [Unit] {
            // Built in steps: as one expression the CI compiler (Xcode 26.6) could not type-check it in time.
            var result: [Unit] = []
            if let stringUnit { result.append(stringUnit) }
            for forms in (variations ?? [:]).values {
                for translation in forms.values { result += translation.units }
            }
            for substitution in (substitutions ?? [:]).values {
                for forms in substitution.variations.values {
                    for translation in forms.values { result += translation.units }
                }
            }
            return result
        }
        var expandedValues: [String] {
            var values: [String] = []
            if let stringUnit {
                values = [stringUnit.value]
            } else {
                for forms in (variations ?? [:]).values {
                    for translation in forms.values { values += translation.expandedValues }
                }
            }
            for (name, substitution) in substitutions ?? [:] {
                let forms = substitution.variations.values.flatMap { $0.values.flatMap(\.expandedValues) }
                values = values.flatMap { value in
                    forms.map { form in
                        value.replacingOccurrences(
                            of: "%#@\(name)@",
                            with: form.replacingOccurrences(
                                of: "%arg", with: "%\(substitution.argNum)$\(substitution.formatSpecifier)"))
                    }
                }
            }
            return values
        }
    }
    private struct Substitution: Decodable {
        let argNum: Int
        let formatSpecifier: String
        let variations: [String: [String: Translation]]
    }
}
