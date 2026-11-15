import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ShortcutPersistenceTests {
    private var environment: ShortcutValidationContext {
        .init(projection: [
            .init(
                logical: .init(key: .character("j"), modifiers: [.control, .option, .command]),
                physical: .init(key: .macVirtualKey(38), modifiers: [.control, .option, .command])),
            .init(
                logical: .init(key: .character("k"), modifiers: [.control, .option, .command]),
                physical: .init(key: .macVirtualKey(40), modifiers: [.control, .option, .command])),
        ])
    }

    @Test("旧Carbon値は物理キーを維持して変換し読み込みでは保存しない")
    func migrationIsReadOnly() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let raw = Data(#"{"keyCode":38,"modifiers":6400}"#.utf8)
        suite.defaults.set(raw, forKey: "openClipboardShortcut")
        suite.defaults.set(Data(#"{"keyCode":40,"modifiers":6400}"#.utf8), forKey: "printClipboardShortcut")
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        #expect(
            preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [
                .init(key: .macVirtualKey(38), modifiers: [.control, .option, .command])
            ])
        #expect(
            preferences.keyboardShortcuts.keys(for: .globalClipboardPrintScreen) == [
                .init(key: .macVirtualKey(40), modifiers: [.control, .option, .command])
            ])
        #expect(preferences.keyboardShortcutsLoadState == .migrationRequired)
        #expect(preferences.keyboardShortcutsRevision == 0)
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
        #expect(suite.defaults.data(forKey: "openClipboardShortcut") == raw)
        #expect(preferences.openClipboardShortcut == KeyCombo(keyCode: 38, modifiers: 6400))
    }

    @Test("移行保存後と全件復元後は旧値を再移行しない")
    func initializationPreventsRemigration() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(Data(#"{"keyCode":38,"modifiers":6400}"#.utf8), forKey: "openClipboardShortcut")
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        try preferences.saveKeyboardShortcutMigration(environment: environment)
        #expect(preferences.keyboardShortcutsRevision == 1)
        let saved = suite.defaults.data(forKey: "keyboardShortcuts.v1")
        try preferences.saveKeyboardShortcutMigration(environment: environment)
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == saved)
        #expect(preferences.keyboardShortcutsRevision == 1)
        let reset = try ShortcutValidator(environment: environment).restoreAll(in: preferences.keyboardShortcuts)
        try preferences.saveKeyboardShortcuts(reset, expectedRevision: 1)
        let restored = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        #expect(restored.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
        #expect(restored.keyboardShortcutsLoadState == .loaded)
        #expect(suite.defaults.data(forKey: "openClipboardShortcut") == Data(#"{"keyCode":38,"modifiers":6400}"#.utf8))
        #expect(restored.openClipboardShortcut == KeyCombo(keyCode: 38, modifiers: 6400))
    }

    @Test("未知版と未知操作と壊れた保存値は旧値に戻さず上書きもしない")
    func unreadableStoreIsPreserved() throws {
        for raw in [
            Data("broken".utf8),
            Data(#"{"schemaVersion":2,"overrides":[],"inactiveMigration":[]}"#.utf8),
            Data(
                #"{"schemaVersion":1,"overrides":[{"operation":"future.action","keys":[]}],"inactiveMigration":[]}"#
                    .utf8),
        ] {
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            suite.defaults.set(raw, forKey: "keyboardShortcuts.v1")
            suite.defaults.set(Data(#"{"keyCode":38,"modifiers":6400}"#.utf8), forKey: "openClipboardShortcut")
            let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
            #expect(preferences.keyboardShortcuts == ShortcutConfiguration())
            #expect(preferences.keyboardShortcutsLoadState.isUnreadable)
            let reset = try ShortcutValidator(environment: environment).restoreAll(in: preferences.keyboardShortcuts)
            #expect(throws: ShortcutPreferencesError.self) {
                try preferences.saveKeyboardShortcuts(reset, expectedRevision: 0)
            }
            #expect(throws: ShortcutPreferencesError.self) {
                try preferences.saveKeyboardShortcutMigration(environment: environment)
            }
            #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == raw)
        }
    }

    @Test("旧値の重複は両方を非アクティブにし原文を保存する")
    func duplicateLegacy() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let raw = Data(#"{"keyCode":38,"modifiers":6400}"#.utf8)
        suite.defaults.set(raw, forKey: "openClipboardShortcut")
        suite.defaults.set(raw, forKey: "printClipboardShortcut")
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
        #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardPrintScreen) == [])
        #expect(preferences.keyboardShortcuts.inactiveMigration.map(\.reasons) == [[.conflict], [.conflict]])
        #expect(preferences.keyboardShortcuts.inactiveMigration.map(\.legacyData) == [raw, raw])
        try preferences.saveKeyboardShortcutMigration(environment: environment)
        #expect(
            try ShortcutStore.decode(#require(suite.defaults.data(forKey: "keyboardShortcuts.v1")))
                == preferences.keyboardShortcuts)
    }

    @Test("旧値の破損と未知修飾ビットは消さず非アクティブにする")
    func invalidLegacy() {
        for raw in [Data("broken".utf8), Data(#"{"keyCode":38,"modifiers":6401}"#.utf8)] {
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            suite.defaults.set(raw, forKey: "openClipboardShortcut")
            let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
            #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
            #expect(preferences.keyboardShortcuts.inactiveMigration.first?.legacyData == raw)
            #expect(preferences.keyboardShortcuts.inactiveMigration.first?.reasons == [.malformedLegacy])
        }
    }

    @Test("予約情報未取得では移行の保存を拒み旧値を保持する")
    func unavailableEnvironment() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(Data(#"{"keyCode":38,"modifiers":6400}"#.utf8), forKey: "openClipboardShortcut")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
        #expect(
            preferences.keyboardShortcuts.inactiveMigration.first?.candidate
                == .init(key: .macVirtualKey(38), modifiers: [.control, .option, .command]))
        #expect(throws: ShortcutPreferencesError.self) {
            try preferences.saveKeyboardShortcutMigration(environment: .unavailable)
        }
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
    }

    @Test("スナップショット保存は版番号を進め古い計画を拒否する")
    func atomicSnapshots() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        let plan = try ShortcutValidator(environment: environment).plan(
            replacing: .documentReload,
            with: [], in: preferences.keyboardShortcuts, resolution: .reject)
        try preferences.saveKeyboardShortcuts(plan, expectedRevision: 0)
        #expect(preferences.keyboardShortcutsRevision == 1)
        #expect(preferences.keyboardShortcuts.keys(for: .documentReload) == [])
        #expect(throws: ShortcutPreferencesError.self) {
            try preferences.saveKeyboardShortcuts(plan, expectedRevision: 0)
        }
        #expect(AppPreferences(defaults: suite.defaults).keyboardShortcuts.keys(for: .documentReload) == [])
        #expect(preferences.openClipboardShortcut == nil)
        #expect(preferences.printClipboardShortcut == nil)
    }
}

@MainActor
struct ShortcutMigrationBoundaryTests {
    @Test("Carbonの四修飾ビットだけを順序付きの新形式へ移す")
    func carbonBits() throws {
        #expect(
            try KeyCombo(keyCode: 38, modifiers: 6912).shortcutCombination()
                == .init(key: .macVirtualKey(38), modifiers: [.control, .option, .shift, .command]))
        #expect(
            try KeyCombo(keyCode: 38, modifiers: 2048).shortcutCombination()
                == .init(key: .macVirtualKey(38), modifiers: .option))
        #expect(throws: ShortcutModelError.self) { try KeyCombo(keyCode: 38, modifiers: 6913).shortcutCombination() }
        #expect(throws: ShortcutModelError.self) { try KeyCombo(keyCode: 55, modifiers: 256).shortcutCombination() }
        #expect(throws: ShortcutModelError.self) { try KeyCombo(keyCode: 128, modifiers: 256).shortcutCombination() }
    }

    @Test("旧グローバルがローカル既定と衝突しても既定を奪わない")
    func localDefaultWins() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let raw = Data(#"{"keyCode":15,"modifiers":256}"#.utf8)
        suite.defaults.set(raw, forKey: "openClipboardShortcut")
        let environment = ShortcutValidationContext(projection: [
            .init(
                logical: .init(key: .character("r"), modifiers: .command),
                physical: .init(key: .macVirtualKey(15), modifiers: .command))
        ])
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        #expect(
            preferences.keyboardShortcuts.keys(for: .documentReload) == [
                .init(key: .character("r"), modifiers: .command)
            ])
        #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
        #expect(preferences.keyboardShortcuts.inactiveMigration.first?.reasons == [.conflict])
        #expect(preferences.keyboardShortcuts.inactiveMigration.first?.legacyData == raw)
    }

    @Test("旧グローバルの静的予約と有効なシステム予約を非アクティブにする")
    func reservedMigration() {
        let cases: [(String, ShortcutCombination, ShortcutCombination, Bool, ShortcutValidationIssue.Code)] = [
            (
                #"{"keyCode":49,"modifiers":256}"#, .init(key: .macVirtualKey(49), modifiers: .command),
                .init(key: .named(.space), modifiers: .command), false, .spotlight
            ),
            (
                #"{"keyCode":38,"modifiers":256}"#, .init(key: .macVirtualKey(38), modifiers: .command),
                .init(key: .character("j"), modifiers: .command), true, .systemReserved
            ),
        ]
        for (json, physical, logical, reserved, reason) in cases {
            let suite = TestDefaultsSuite()
            defer { suite.remove() }
            let raw = Data(json.utf8)
            suite.defaults.set(raw, forKey: "openClipboardShortcut")
            let preferences = AppPreferences(
                defaults: suite.defaults,
                shortcutEnvironment: .init(
                    reservations: [.init(combination: physical, isEnabled: reserved)],
                    projection: [.init(logical: logical, physical: physical)]))
            #expect(preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [])
            #expect(preferences.keyboardShortcuts.inactiveMigration.first?.reasons == [reason])
            #expect(preferences.keyboardShortcuts.inactiveMigration.first?.legacyData == raw)
        }
    }

    @Test("Data以外の保存値も読み込みや保存で消さない")
    func wrongStorageType() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set("future-format", forKey: "keyboardShortcuts.v1")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.keyboardShortcutsLoadState == .unreadable(.malformedStore))
        #expect(suite.defaults.string(forKey: "keyboardShortcuts.v1") == "future-format")
        #expect(throws: ShortcutPreferencesError.self) {
            try preferences.saveKeyboardShortcutMigration(environment: .init())
        }
        #expect(suite.defaults.string(forKey: "keyboardShortcuts.v1") == "future-format")
    }

    @Test("旧レコーダーの変更は新保存ができるまでは移行候補へ反映する")
    func legacyRefresh() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let environment = ShortcutValidationContext(projection: [
            .init(
                logical: .init(key: .character("j"), modifiers: .command),
                physical: .init(key: .macVirtualKey(38), modifiers: .command))
        ])
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: environment)
        preferences.openClipboardShortcut = .init(keyCode: 38, modifiers: 256)
        preferences.reloadKeyboardShortcuts(environment: environment)
        #expect(
            preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [
                .init(key: .macVirtualKey(38), modifiers: .command)
            ])
        #expect(preferences.keyboardShortcutsRevision == 1)
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
        try preferences.saveKeyboardShortcutMigration(environment: environment)
        preferences.openClipboardShortcut = nil
        let saved = suite.defaults.data(forKey: "keyboardShortcuts.v1")
        preferences.reloadKeyboardShortcuts(environment: environment)
        #expect(
            preferences.keyboardShortcuts.keys(for: .globalClipboardOpen) == [
                .init(key: .macVirtualKey(38), modifiers: .command)
            ])
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == saved)
    }

    @Test("別インスタンスが保存したデータは古い計画で上書きしない")
    func externalWrite() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults, shortcutEnvironment: .init())
        let plan = try ShortcutValidator(environment: .init()).restoreAll(in: preferences.keyboardShortcuts)
        let other = Data("external-change".utf8)
        suite.defaults.set(other, forKey: "keyboardShortcuts.v1")
        #expect(throws: ShortcutPreferencesError.self) {
            try preferences.saveKeyboardShortcuts(plan, expectedRevision: 0)
        }
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == other)
    }
}
