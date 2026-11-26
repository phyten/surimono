import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct LanguageTests {
    @Test("文言のカタログに同じキーが二度ない")
    func catalogKeysAreUnique() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: "App/Localizable.xcstrings"), encoding: .utf8)
        // Two branches can each add the same key, and a text merge keeps both; a JSON parser then silently keeps
        // only the last one. Top-level entries sit at four spaces of indentation.
        let entry = try Regex(#"(?m)^    ("(?:[^"\\]|\\.)*")\s*:\s*\{"#)
        var seen = Set<Substring>()
        var duplicates: [Substring] = []
        for match in text.matches(of: entry) {
            guard let key = match.output[1].substring else { continue }
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        #expect(seen.count > 1000)
        #expect(duplicates.isEmpty, "\(duplicates)")
    }

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

    @Test("目次の置き方を用紙のレイアウトと区別し、原稿どおりの組み方の訳を保つ", arguments: UILanguage.supported)
    func contentsTerms(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        func term(_ key: String) throws -> String {
            let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
            try #require(value != "MISSING")
            return value
        }
        #expect(try term("Placement") != term("Layout"))
        if language == "en" { #expect(try term("Table of Contents at the Top") == "Lead Contents") }
        if language == "ja" {
            #expect(try term("As Written") == term("As They Are"))
            #expect(try term(LaTeXComposition.document.titleKey) == "文書の指定")
        }
    }

    @Test("語数の中央値は各言語で1語と小数と複数の単位を選ぶ")
    func medianWords() throws {
        for (language, expected) in [
            ("en", ["1 word", "1.5 words", "2 words"]), ("de", ["1 Wort", "1,5 Wörter", "2 Wörter"]),
            ("es", ["1 palabra", "1,5 palabras", "2 palabras"]), ("fr", ["1 mot", "1,5 mot", "2 mots"]),
        ] {
            let bundle = try #require(
                Bundle.main.url(forResource: language, withExtension: "lproj").flatMap { Bundle(url: $0) })
            let locale = Locale(identifier: language)
            #expect([1.0, 1.5, 2.0].map { ProsePanel.words($0, bundle: bundle, locale: locale) } == expected)
        }
    }

    @Test("文章の確認の分類名と空の表示を各言語の用語に合わせ紙面で見つからない理由を読み上げる")
    func writingTerms() throws {
        let empty = "No repetitions or long sentences found."
        for (language, key, expected) in [
            ("ko", "Repeated Word", "연달아 나온 같은 단어"), ("ko", "Close Repetition", "가까이 쓰인 같은 단어"),
            ("de", "Close Repetition", "Wiederholungen in kurzem Abstand"),
            ("de", "Kanji %1$@ · Kana %2$@ · Latin %3$@", "Kanji %1$@ · Kana %2$@ · Lateinisch %3$@"),
            ("en", empty, empty), ("es", empty, "No se encontraron repeticiones ni oraciones largas."),
            ("fr", empty, "Aucune répétition ni phrase longue détectée."), ("ja", empty, "見つかりませんでした"),
            ("ja", "Repeated Word", "続いた語"), ("ja", "There is no prose to check.", "本文がありません"),
        ] {
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            #expect(bundle.localizedString(forKey: key, value: "MISSING", table: nil) == expected)
        }
        for language in ["en", "de", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant"] {
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            #expect(
                bundle.localizedString(
                    forKey: "Could not locate this passage on the page.", value: "MISSING", table: nil) != "MISSING")
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

    @Test("LaTeX の認識名と説明の文言が八言語にある")
    func latexBadgeCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        for key in [
            "%@ (submission)",
            "%@ (final)",
            "%@ (preprint)",
            "%@ (rebuttal)",
            "%@ (draft)",
            "standard layout",
            "Shown as the document specifies (%@).",
            "The class “%@” is not supported, so the standard layout is used.",
            "Line and page breaks may differ from LaTeX output.",
        ] {
            let entry = try #require(catalog.strings[key])
            #expect(Set(entry.localizations.keys) == ["ja", "en", "zh-Hans", "zh-Hant", "fr", "de", "es", "ko"])
        }
    }

    @Test("設定の検索に載せる項目名と区分名はすべて文言カタログの8言語にある")
    func settingsSearchLabels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self,
            from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        let keys =
            SettingsCatalogue.rows.map(\.label) + SettingsGroup.allCases.map(\.rawValue)
            + SettingsSection.allCases.map(\.rawValue) + ["Your Sets", "Built-in Sets"]
        for key in Set(keys) {
            let entry = try #require(catalog.strings[key], "\(key)")
            for language in UILanguage.supported {
                let translation = try #require(entry.localizations[language], "\(key): \(language)")
                #expect(translation.units.contains { $0.state == "translated" && !$0.value.isEmpty })
            }
        }
    }

    @Test("設定は区分名と表示名を部分一致で探せ、かなと文字幅が違っても英語名でも見つかる")
    func settingsSearch() {
        let row = SettingsSearchRow(.printing, "Text Margins")
        let names = ["Printing": "印刷", "Text Margins": "テキストの余白"]
        for query in ["刷", "きすと", "ｷｽﾄ", "ＰＲＩＮＴ", "marg"] {
            #expect(SettingsCatalogue.search(query, in: [row], localize: { names[$0] ?? $0 }).rows.count == 1)
        }
        #expect(SettingsCatalogue.search("見出し", in: [row]).rows.isEmpty)
        #expect(
            SettingsGroup.allCases.flatMap(\.sections) == [
                .general, .keyboardShortcuts, .view, .toolbarArrangement, .styles,
                .printing, .pageNumbers, .settingSets, .clipboard, .org, .html,
            ])
    }

    @Test("ショートカット画面が参照するキーはカタログに存在し8言語で翻訳されている")
    func shortcutCatalogCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        // Include dialogs, registration errors and spoken key names, not just the visible top rows.
        let files = [
            "ShortcutSettingsView", "ShortcutText", "ShortcutRecorder", "ShortcutController",
            "SystemShortcutReservations", "ShortcutArchiveFiles", "ShortcutImportView", "ShortcutHints",
            "SettingsSearchField",
        ]
        let pattern =
            #"(?:String\(\s*localized:\s*|SettingsSearchField\(title:\s*|(?:Text|TextField|Button|Label|Picker|Section|Toggle)\(\s*)"([^"\\]*(?:\\.[^"\\]*)*)""#
        let expression = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = [SettingsSection.keyboardShortcuts.rawValue]
        for file in files {
            let source = try String(contentsOf: root.appending(path: "App/\(file).swift"), encoding: .utf8)
            let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
            #expect(!matches.isEmpty, "No localization references found in \(file)")
            for match in matches {
                let range = try #require(Range(match.range(at: 1), in: source))
                let literal = "\"" + source[range] + "\""
                let key = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
                if !key.isEmpty { keys.insert(key) }
            }
        }
        #expect(keys.contains("Search Shortcuts"))
        keys.formUnion(ShortcutOperation.catalog.map { ShortcutText.nameResource($0.id).key })
        #expect(keys.contains("Open…"))
        #expect(keys.contains("Left Arrow"))
        #expect(keys.contains("Record Shortcut"))
        #expect(keys.contains("Registered"))
        keys.formUnion(["In Surimono", "Printing and Export", "Global"])
        #expect(keys.contains("Merge Imported Shortcuts"))
        #expect(keys.contains("Restore All Defaults?"))
        #expect(keys.contains("Restore All Defaults"))
        #expect(keys.contains("Custom assignments to remove: %lld"))
        #expect(keys.contains("Shortcut Actions"))
        for key in keys.sorted() {
            let entry = try #require(catalog.strings[key], "Missing shortcut key: \(key)")
            for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
                let translation = try #require(entry.localizations[language], "\(key): \(language)")
                #expect(!translation.units.isEmpty, "\(key): \(language)")
                for unit in translation.units {
                    #expect(unit.state == "translated" && !unit.value.isEmpty, "\(key): \(language)")
                }
                for value in translation.expandedValues {
                    #expect(specifiers(value) == specifiers(key), "\(key): \(language)")
                }
            }
        }
    }

    @Test("閉じたクリップボード文書の保存設定・説明・消去には8言語の翻訳がある")
    func clipboardRetentionCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        for key in [
            "Also Keep Them After Quitting", "Saved on this Mac until you reopen or clear them, for up to 7 days.",
            "Clear Closed Clipboard Documents",
        ] {
            let entry = try #require(catalog.strings[key])
            for language in ["en", "ja", "de", "es", "fr", "ko", "zh-Hans", "zh-Hant"] {
                let unit = try #require(entry.localizations[language]?.stringUnit)
                #expect(unit.state == "translated" && !unit.value.isEmpty)
            }
        }
    }

    @Test("ツールバーの配置画面の文言と読み上げには8言語の翻訳がある")
    func arrangementEditorCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        // Every literal the editor localizes: titles, help, messages, announcements and the parts' descriptions.
        let literal =
            #/(?:String\(localized:\s*|Text\(|Button\(|Label\(|\.help\(|LocalizedStringKey\(|Picker\(|TextField\()\s*"((?:[^"\\]|\\.)*)"/#
        var keys = Set<String>()
        for file in [
            "BandArrangementSettings.swift", "BandArrangementEditorSession.swift", "BandPartPresentation.swift",
            "BandMenuContent.swift", "BandPaletteGroup.swift", "BandAdditionalPart.swift",
        ] {
            let source = try String(contentsOf: root.appending(path: "App/\(file)"), encoding: .utf8)
            for match in source.matches(of: literal) { keys.insert(String(match.output.1)) }
        }
        #expect(keys.count > 100)
        for key in keys {
            // An interpolated value is a format specifier in the catalog's key.
            let candidates = ["%@", "%lld"].map { key.replacing(#/\\\([^)]*\)/#, with: $0) }
            let entry = try #require(candidates.lazy.compactMap { catalog.strings[$0] }.first, "\(key)")
            for language in ["en", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "de", "es"] {
                let units = try #require(entry.localizations[language], "\(key): \(language)").units
                #expect(!units.isEmpty && units.allSatisfy { $0.state == "translated" }, "\(key): \(language)")
            }
        }
    }

    @Test("ドイツ語の省略記号には空白があり繁体字はU2026を使い保存部品名に省略記号を付けない")
    func toolbarTranslationPunctuation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        for (key, entry) in catalog.strings {
            for unit in entry.localizations["de"]?.units ?? [] {
                // Quoted “…” names the literal More control, not a command with an ellipsis suffix.
                let value = unit.value.replacingOccurrences(of: "„…“", with: "")
                #expect(value.firstMatch(of: #/[^\s]…/#) == nil, "\(key): \(value)")
            }
            for unit in entry.localizations["zh-Hant"]?.units ?? [] {
                #expect(!unit.value.contains("⋯"), "\(key)")
            }
        }
        let save = try #require(catalog.strings["Save as File"])
        #expect(save.localizations["de"]?.stringUnit?.value == "Als Datei sichern")
        #expect(save.localizations["zh-Hant"]?.stringUnit?.value == "儲存為檔案")
        #expect(catalog.strings["Vertical Scroll"]?.localizations["ja"]?.stringUnit?.value == "縦スクロール")
        #expect(catalog.strings["Horizontal Scroll"]?.localizations["ja"]?.stringUnit?.value == "横スクロール")
    }

    @Test("画面・合本・画像の束などの用語をそれぞれの言語で統一する")
    func consistentTerms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        let discontinued = [
            "ja": ["刷り台", "フォルダー", "綴じ方", "割当", "他のアプリ", "印刷設定", "いまの", "見比べ台"],
            "de": [
                "Sammlung", "Sammeldokument", "Bildsammlung", "Bilderbündel", "Druckansicht", "Druckbogen",
                "Druckbögen",
            ],
            "es": ["recopilación", "recopilaciones", "conjunto de imágenes", "conjuntos de imágenes"],
            "zh-Hans": ["文稿", "打印画面", "打印屏幕", "图片组", "图像组"],
            "zh-Hant": ["開啟", "匯出", "圖片", "影像組", "資料夾"],
        ]
        for (key, entry) in catalog.strings {
            for (language, terms) in discontinued {
                for unit in entry.localizations[language]?.units ?? [] {
                    for term in terms where unit.value.localizedCaseInsensitiveContains(term) {
                        Issue.record("\(key) [\(language)] \(term) — \(unit.value)")
                    }
                }
            }
        }

        let expected: [(String, String, String)] = [
            ("ja", "Show Update…", "アップデートを表示…"),
            ("ja", "Update Available", "アップデートがあります"),
            ("ja", "When an Update Is Found", "アップデートが見つかったとき"),
            ("ja", "Updating pages…", "ページを更新中…"),
            ("ja", "Unassigned", "未割り当て"),
            ("ja", "Open Styles Folder", "自分のスタイルのフォルダを開く"),
            ("ja", "Left Drawer", "左の引き出し"),
            (
                "ja",
                "The binding changed in the print dialog. Run the duplex test again without changing the binding.",
                "システムの印刷画面でとじ方が変わりました。とじ方を変えずに、もう一度両面のテスト印刷をしてください。"
            ),
            ("de", "In binders and image bundles", "In Sammelbänden und Bilderstapeln"),
            ("de", "Open the print screen", "Druckbildschirm öffnen"),
            ("es", "In binders and image bundles", "En compilaciones y lotes de imágenes"),
            (
                "es", "Updates are unavailable in this build.",
                "Las actualizaciones no están disponibles en esta versión."
            ),
            ("es", "Toolbar Layout", "Estructura de la barra de herramientas"),
            ("es", "Always Show Toolbar", "Mostrar siempre la barra"),
            ("es", "Toolbar Arrangement", "Disposición de la barra"),
            ("zh-Hans", "Open Sample Document", "打开示例文档"),
            ("zh-Hans", "Open the print screen", "打开打印界面"),
            ("zh-Hans", "In binders and image bundles", "在合订本和图像集中"),
            ("zh-Hant", "Open the print screen", "打開列印畫面"),
            ("zh-Hant", "Export Shortcuts…", "輸出快速鍵…"),
            ("zh-Hant", "In binders and image bundles", "在合訂本與影像集中"),
            ("de", "PDF of Sheets…", "Blätter als PDF …"),
            ("de", "Export the sheets as a PDF", "Blätter wie angeordnet als PDF exportieren"),
            ("zh-Hans", "Paper: %@", "纸张：%@"),
            ("zh-Hant", "Paper: %@", "紙張：%@"),
            ("zh-Hans", "Paper %1$@ · %2$@ · %3$@", "纸张 %1$@ · %2$@ · %3$@"),
            ("zh-Hant", "Paper %1$@ · %2$@ · %3$@", "紙張 %1$@ · %2$@ · %3$@"),
            ("ko", "Window", "윈도우"),
            ("ko", "Shows this window on every desktop.", "모든 데스크탑에 이 창을 표시합니다."),
        ]
        for (language, key, value) in expected {
            #expect(catalog.strings[key]?.localizations[language]?.stringUnit?.value == value, "\(key) [\(language)]")
        }
    }

    @Test("韓国語では印刷を 인쇄、機器を 프린터 と呼ぶ")
    func koreanPrintTerminology() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App")
        for table in ["Localizable", "ServicesMenu", "Shortcuts", "AppShortcuts"] {
            let catalog = try JSONDecoder().decode(
                Catalog.self, from: Data(contentsOf: app.appending(path: "\(table).xcstrings")))
            for (key, entry) in catalog.strings {
                let korean = try #require(entry.localizations["ko"], "\(table): \(key)")
                let values = korean.units.map(\.value) + (korean.stringSet?.values ?? [])
                #expect(!values.isEmpty, "\(table): \(key)")
                for value in values {
                    #expect(!value.contains("프린트"), "\(table): \(key) — \(value)")
                }
            }
        }
    }

    @Test("フランス語のコロンと疑問符・感嘆符・セミコロンは直前の語と同じ行に収まる")
    func frenchPunctuationSpacing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        let spacing: [Character: Character] = [":": "\u{00A0}", "?": "\u{202F}", "!": "\u{202F}", ";": "\u{202F}"]
        for (key, entry) in catalog.strings {
            for unit in entry.localizations["fr"]?.units ?? [] {
                // Org keywords such as #+TOC: and :UNNUMBERED: are shown as the reader types them, so their
                // colons belong to the syntax and take no French spacing.
                let syntax = unit.value.ranges(of: #/#\+[A-Z_]+:|:[A-Z_]+:/#)
                for index in unit.value.indices {
                    guard let space = spacing[unit.value[index]] else { continue }
                    if syntax.contains(where: { $0.contains(index) }) { continue }
                    #expect(
                        index != unit.value.startIndex && unit.value[unit.value.index(before: index)] == space,
                        "\(key) — \(unit.value)")
                }
            }
        }
    }

    private func specifiers(_ text: String) -> [String] {
        let pattern = #/%(?:(\d+)\$)?(lld|ld|\.15g|@)/#
        return text.matches(of: pattern).enumerated().map { index, match in
            let position = match.output.1.map(String.init) ?? String(index + 1)
            return "\(position):\(match.output.2)"
        }.sorted()
    }

    @Test("韓国語のウインドウは 창 と書き、윈도우 は macOS のメニューの名前に合わせる 3 つだけ")
    func koreanWindow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "App/Localizable.xcstrings")))
        // macOS adds its own 윈도우 items to the Window menu, so the menu's own names match them.
        let systemNames: Set<String> = ["Window", "Close Window", "Cycle Windows"]
        for (key, entry) in catalog.strings where !systemNames.contains(key) {
            for unit in entry.localizations["ko"]?.units ?? [] {
                #expect(!unit.value.contains("윈도우"), "\(key): \(unit.value)")
            }
        }
        for key in systemNames {
            #expect(catalog.strings[key]?.localizations["ko"]?.stringUnit?.value.contains("윈도우") == true, "\(key)")
        }
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
    private struct PhraseSet: Decodable { let values: [String] }
    private struct Translation: Decodable {
        let stringSet: PhraseSet?
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
