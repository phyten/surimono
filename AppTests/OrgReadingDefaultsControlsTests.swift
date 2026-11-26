import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct OrgReadingDefaultsControlsTests {
    @Test("現在値から状態名と二つのボタンの有効状態を決める")
    func statusAndActions() {
        var custom = OrgReadingDefaults.surimono
        custom.headlineLevels = 5
        for (current, status, useEmacs, reset) in [
            (OrgReadingDefaults.surimono, "Surimono defaults", true, false),
            (.emacs, "Emacs defaults", false, true),
            (custom, "Custom", true, true),
        ] {
            let defaults = OrgReadingDefaultsPane.defaults(current)
            #expect(defaults.status?.key == status)
            #expect(defaults.canApply(.emacs) == useEmacs)
            #expect(defaults.canApply(.surimono) == reset)
        }
    }

    @Test("別の初期値がなければ状態名を出さず、複数あれば一致する組を選ぶ")
    func alternatives() {
        let empty = ReadingDefaults(builtIn: 1, alternatives: [], current: 2)
        #expect(empty.status == nil)
        let many = ReadingDefaults(
            builtIn: 1,
            alternatives: [
                .init(values: 2, status: "Two", action: "Use Two…", confirmation: "Use Two", question: "Use Two?"),
                .init(
                    values: 3, status: "Three", action: "Use Three…", confirmation: "Use Three", question: "Use Three?"),
            ], current: 3)
        #expect(many.status?.key == "Three")
        #expect(many.canApply(1) && many.canApply(2) && !many.canApply(3))
    }

    @Test("初期値から Emacs にするときは一覧と同じ名前と値で六つの差を順に示す")
    func emacsChanges() {
        let changes = OrgReadingDefaultsPane.differences(from: .surimono, to: .emacs)
        let expected: [(LocalizedStringResource, LocalizedStringResource, LocalizedStringResource)] = [
            ("Heading Numbers", "None", "All Levels"),
            ("Table of Contents at the Top", "None", "All Levels"),
            ("Clock Lines", "On", "Off"),
            ("Subscripts and Superscripts", "Only in { }", "Even without { }"),
            ("Drawers", "Don't Show", "Show All Except LOGBOOK"),
            ("Archived Trees", "Entire Tree", "Heading Only"),
        ]
        #expect(changes.count == expected.count)
        for (change, labels) in zip(changes, expected) {
            #expect(change.name == String(localized: labels.0))
            #expect(change.current == String(localized: labels.1))
            #expect(change.new == String(localized: labels.2))
        }
        #expect(OrgReadingDefaultsPane.differences(from: .emacs, to: .emacs).isEmpty)
    }

    @Test("すでに Emacs と同じ項目があっても残りの五項目は確認する")
    func partiallyMatchingEmacs() {
        var current = OrgReadingDefaults.surimono
        current.sectionNumbers = .all
        let changes = OrgReadingDefaultsPane.differences(from: current, to: .emacs)
        #expect(OrgReadingDefaultsPane.defaults(current).canApply(.emacs))
        #expect(changes.count == 5)
        #expect(!changes.contains { $0.name == String(localized: "Heading Numbers") })
    }

    @Test("手で変えた項目だけを確認し、一致する値は上書きの一覧から除く")
    func customChanges() {
        var custom = OrgReadingDefaults.emacs
        custom.tableOfContents = .off
        custom.planning = true
        let toEmacs = OrgReadingDefaultsPane.differences(from: custom, to: .emacs)
        #expect(
            toEmacs.map(\.name) == [
                String(localized: "Table of Contents at the Top"), String(localized: "Planning Lines"),
            ])
        let reset = OrgReadingDefaultsPane.differences(from: custom, to: .surimono)
        #expect(reset.count == 6)
        #expect(!reset.contains { $0.name == String(localized: "Table of Contents at the Top") })
        #expect(reset.contains { $0.name == String(localized: "Planning Lines") && $0.new == String(localized: "Off") })
    }

    @Test("ドロワーとプロパティの全表示には同じ値名を使う")
    func drawerChoices() {
        var all = OrgReadingDefaults.surimono
        all.drawers = .all
        all.properties = .all
        let changes = OrgReadingDefaultsPane.differences(from: .surimono, to: all)
        #expect(changes.count == 2)
        for change in changes {
            #expect(change.current == String(localized: "Don't Show"))
            #expect(change.new == String(localized: "Show All"))
        }
    }

    @Test("Emacs とリセットの確定ボタンは実行する操作を示し、日本語の見出しは全角疑問符で終わる")
    func confirmationButtons() throws {
        let defaults = OrgReadingDefaultsPane.defaults(.surimono)
        let emacs = try #require(defaults.alternatives.first)
        let reset = defaults.reset(question: "Reset Org settings to defaults?")
        #expect(emacs.action.key == "Use Emacs Defaults…")
        #expect(emacs.confirmation.key == "Use Emacs Defaults")
        #expect(reset.action.key == "Reset to Defaults…")
        #expect(reset.confirmation.key == "Reset")
        let url = try #require(Bundle.main.url(forResource: "ja", withExtension: "lproj"))
        let ja = try #require(Bundle(url: url))
        #expect(ja.localizedString(forKey: emacs.confirmation.key, value: nil, table: nil) == "Emacs の初期値にする")
        #expect(ja.localizedString(forKey: emacs.question.key, value: nil, table: nil) == "Emacs の初期値にしますか？")
        #expect(ja.localizedString(forKey: reset.question.key, value: nil, table: nil) == "Org の設定を初期値に戻しますか？")
    }

    @Test("八言語で適用とリセットの件数・単複と、空行・省略行まで一致する", arguments: UILanguage.supported, [1, 2, 8, 9])
    func confirmationLayout(language: String, count: Int) throws {
        let changes: [ReadingSettingChange] = (1...count).map { ("item \($0)", "A", "B") }
        let bullet = language == "ja" ? "・" : "• "
        let visible = count == 9 ? 6 : count
        var entries = (1...visible).map { "\(bullet)item \($0)\nA → B" }
        if count == 9 {
            let remaining = [
                "en": "• and 3 more", "ja": "・ほか 3 項目", "de": "• und 3 weitere", "es": "• y 3 más",
                "fr": "• et 3 autres", "ko": "• 외 3개", "zh-Hans": "• 另有 3 项", "zh-Hant": "• 另有 3 項",
            ]
            entries.append(try #require(remaining[language]))
        }
        let headings = try #require(Self.expectedHeadings(language: language, count: count))
        for (resetting, heading) in [(false, headings.change), (true, headings.reset)] {
            let actual = ReadingDefaultsConfirmation.message(resetting: resetting, changes: changes, language: language)
            #expect(actual == ([heading] + entries).joined(separator: "\n\n"))
        }
    }

    private static func expectedHeadings(language: String, count n: Int) -> (change: String, reset: String)? {
        switch (language, n) {
        case ("en", 1):
            ("The following 1 setting will change:", "The following 1 setting will reset to Surimono defaults:")
        case ("en", _):
            ("The following \(n) settings will change:", "The following \(n) settings will reset to Surimono defaults:")
        case ("de", 1):
            ("1 Einstellung wird geändert:", "1 Einstellung wird auf den Surimono-Standardwert zurückgesetzt:")
        case ("de", _):
            (
                "Die folgenden \(n) Einstellungen werden geändert:",
                "Die folgenden \(n) Einstellungen werden auf die Surimono-Standardwerte zurückgesetzt:"
            )
        case ("es", 1): ("Se cambiará 1 ajuste:", "Se restablecerá el valor inicial de Surimono en 1 ajuste:")
        case ("es", _):
            (
                "Se cambiarán los siguientes \(n) ajustes:",
                "Se restablecerán los valores iniciales de Surimono en los siguientes \(n) ajustes:"
            )
        case ("fr", 1): ("1 réglage sera modifié :", "1 réglage retrouvera sa valeur initiale de Surimono :")
        case ("fr", _):
            (
                "Les \(n) réglages suivants seront modifiés :",
                "Les \(n) réglages suivants retrouveront leurs valeurs initiales de Surimono :"
            )
        case ("ja", _): ("次の \(n) 項目が変わります。", "次の \(n) 項目が Surimono の初期値に戻ります。")
        case ("ko", _): ("다음 설정 \(n)개가 변경됩니다:", "다음 설정 \(n)개가 Surimono 초깃값으로 재설정됩니다:")
        case ("zh-Hans", _): ("将更改以下 \(n) 项设置：", "以下 \(n) 项设置将恢复为 Surimono 初始值：")
        case ("zh-Hant", _): ("將更改以下 \(n) 項設定：", "以下 \(n) 項設定將回復為 Surimono 初始值：")
        default: nil
        }
    }

    @Test("全項目が変わる場合まで省略行を含めた表示件数が八件を超えない")
    func entryLimit() {
        let changes: [ReadingSettingChange] = OrgSettingID.allCases.map { ($0.rawValue, "A", "B") }
        for count in 1...changes.count {
            let message = ReadingDefaultsConfirmation.message(resetting: false, changes: Array(changes.prefix(count)))
            let entries = message.components(separatedBy: "\n\n").dropFirst()
            #expect(entries.count == (count <= 8 ? count : 7))
        }
    }

    @Test("八言語で下付き・上付きの選択肢に波括弧を残し、空表示には比較対象を示す", arguments: UILanguage.supported)
    func bracesAndEmptyState(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        func translated(_ key: String) -> String { bundle.localizedString(forKey: key, value: "MISSING", table: nil) }
        #expect(translated("Only in { }").contains("{ }"))
        #expect(translated("Even without { }").contains("{ }"))
        let key = "No settings differ from Surimono defaults"
        #expect(translated(key).contains("Surimono"))
        if language == "ja" { #expect(translated(key) == "Surimono の初期値と違う設定はありません") }
    }

    @Test("初期値でも絞り込みをオンにでき、手動で差を消すと空表示を保ち、一括リセットで解除する")
    func changedFilter() {
        var filter = OrgChangedSettingsFilter()
        #expect(!filter.isOn && !filter.showsEmpty(.surimono))
        filter.isOn = true
        #expect(filter.showsEmpty(.surimono))
        filter.didApply(.emacs)
        #expect(filter.isOn && !filter.showsEmpty(.emacs))
        #expect(filter.showsEmpty(.surimono))
        filter.didApply(.surimono)
        #expect(!filter.isOn && !filter.showsEmpty(.surimono))
    }

    #if DEBUG
        @Test("撮影用の初期値・絞り込み・確認先を組み合わせ、一致する操作ではアラートを待たない")
        func snapshotStates() throws {
            typealias Fixture = DebugSnapshot.OrgDefaultsFixture
            #expect(Fixture(state: nil, alert: nil, changedOnly: false) == nil)
            let empty = try #require(Fixture(state: nil, alert: nil, changedOnly: true))
            #expect(empty.current == .surimono && empty.changedOnly && empty.target == nil)
            let emacs = try #require(Fixture(state: "emacs", alert: "emacs", changedOnly: true))
            #expect(emacs.current == .emacs && emacs.target == nil && emacs.changedOnly)
            let reset = try #require(Fixture(state: nil, alert: "reset", changedOnly: false))
            #expect(reset.current == .emacs && reset.target == .surimono)
            let custom = try #require(Fixture(state: "custom", alert: "emacs", changedOnly: true))
            #expect(custom.current.changedIDs(from: .emacs) == [.tableOfContents, .planning])
            #expect(custom.target == .emacs && custom.changedOnly)
        }
    #endif
}
