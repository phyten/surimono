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
            ("Subscripts and Superscripts", "Only in { }", "Even without { }"),
            ("Clock Lines", "On", "Off"),
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

    @Test("八言語で二行の項目を空行で区切り、八件を超えたら残り件数も独立した項目にする", arguments: UILanguage.supported)
    func confirmationLayout(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        let changes: [ReadingSettingChange] = (1...9).map { ("item \($0)", "A", "B") }
        let bullet = language == "ja" ? "・" : "• "
        let rows = (1...8).map { "\(bullet)item \($0)\nA → B" }
        let eight = ReadingDefaultsConfirmation.message(
            heading: "Lead", changes: Array(changes.prefix(8)), bundle: bundle)
        #expect(eight == "Lead\n\n" + rows.joined(separator: "\n\n"))
        let remaining = [
            "en": "• and 3 more", "ja": "・ほか 3 項目", "de": "• und 3 weitere", "es": "• y 3 más",
            "fr": "• et 3 autres", "ko": "• 외 3개", "zh-Hans": "• 另有 3 项", "zh-Hant": "• 另有 3 項",
        ]
        let last = try #require(remaining[language])
        let nine = ReadingDefaultsConfirmation.message(heading: "Lead", changes: changes, bundle: bundle)
        #expect(nine == "Lead\n\n" + (Array(rows.prefix(6)) + [last]).joined(separator: "\n\n"))
    }

    @Test("全項目が変わる場合まで省略行を含めた表示件数が八件を超えない")
    func entryLimit() {
        let changes: [ReadingSettingChange] = OrgSettingID.allCases.map { ($0.rawValue, "A", "B") }
        for count in 1...changes.count {
            let message = ReadingDefaultsConfirmation.message(heading: "Lead", changes: Array(changes.prefix(count)))
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
