import AppKit
import Carbon.HIToolbox
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ShortcutControllerTests {
    private static let j = ShortcutCombination(key: .macVirtualKey(38), modifiers: [.command, .control, .option])
    private static let k = ShortcutCombination(key: .macVirtualKey(40), modifiers: [.command, .control, .option])
    private static let layout = ShortcutKeyboardLayout.project { code, flags in
        switch code {
        case 38: "j"
        case 40: "k"
        case 35: "p"
        case 20: flags.contains(.shift) ? "#" : "3"
        default: nil
        }
    }

    @MainActor
    private final class Backend {
        var calls: [String] = []
        var fail: Set<KeyCombo> = []
        var ids: [KeyCombo: UInt32] = [:]
        var beforeRegister: () -> Void = {}
        lazy var hotKeys = GlobalHotKeys(
            register: { [self] combo, id in
                calls.append("register:\(combo.keyCode)")
                beforeRegister()
                if fail.contains(combo) { return nil }
                ids[combo] = id
                return { self.calls.append("release:\(combo.keyCode)") }
            }, activate: { [self] in calls.append("activate") },
            openClipboard: { [self] in calls.append($0 ? "printScreen" : "open") })
    }

    private func controller(_ backend: Backend, reservations: @escaping () -> [ShortcutSystemReservation]? = { [] })
        -> ShortcutController
    {
        ShortcutController(hotKeys: backend.hotKeys, reservations: reservations, keyboardLayout: { Self.layout })
    }

    @Test("旧キーは登録時には未保存で登録成功後に新ストアだけを参照する")
    func migrationOrdering() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        backend.beforeRegister = { #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil) }
        let controller = controller(backend)
        controller.start(preferences: preferences)
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        #expect(preferences.keyboardShortcutsLoadState == .loaded)
        #expect(backend.calls == ["register:38"])
        backend.beforeRegister = {}
        preferences.openClipboardShortcut = KeyCombo(Self.k)
        controller.refresh()
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        #expect(backend.calls == ["register:38"])
    }

    @Test("旧キーがなければ登録せず両方未割当のまま移行する")
    func emptyMigration() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        let preferences = AppPreferences(defaults: suite.defaults)
        let controller = controller(backend)
        controller.start(preferences: preferences)
        #expect(backend.calls.isEmpty)
        #expect(controller.snapshot.keys(for: .globalClipboardOpen).isEmpty)
        #expect(controller.snapshot.keys(for: .globalClipboardPrintScreen).isEmpty)
        #expect(preferences.keyboardShortcutsLoadState == .loaded)
    }

    @Test("移行の登録失敗では新ストアを書かず以前の登録を維持する")
    func failedMigration() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        preferences.printClipboardShortcut = KeyCombo(Self.k)
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        try backend.hotKeys.apply([try #require(KeyCombo(Self.j)): .open])
        backend.fail.insert(try #require(KeyCombo(Self.k)))
        let controller = controller(backend)
        controller.start(preferences: preferences)
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
        #expect(backend.hotKeys.isRegistered(.open))
        #expect(!backend.calls.contains("release:38"))
        #expect(controller.migrationError != nil)
    }

    @Test("新規登録の失敗では保存値と以前の登録を変えない")
    func failedEdit() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        try controller.edit(.globalClipboardOpen, keys: [Self.j])
        let saved = suite.defaults.data(forKey: "keyboardShortcuts.v1")
        backend.fail.insert(try #require(KeyCombo(Self.k)))
        #expect(throws: GlobalHotKeys.RegistrationError.self) {
            try controller.edit(.globalClipboardOpen, keys: [Self.k])
        }
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == saved)
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        #expect(!backend.calls.contains("release:38"))
    }

    @Test("保存の競合では新しい登録だけを解放して以前の登録を維持する")
    func saveRollback() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        try controller.edit(.globalClipboardOpen, keys: [Self.j])
        backend.beforeRegister = { suite.defaults.set(Data("external".utf8), forKey: "keyboardShortcuts.v1") }
        #expect(throws: ShortcutPreferencesError.self) {
            try controller.edit(.globalClipboardOpen, keys: [Self.k])
        }
        #expect(backend.calls == ["register:38", "register:40", "release:40"])
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == Data("external".utf8))
    }

    @Test("グローバル間の重複は選択前には変えず選択後は登録を再利用する")
    func transfer() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        try controller.edit(.globalClipboardOpen, keys: [Self.j])
        #expect(throws: ShortcutModelError.self) {
            try controller.edit(.globalClipboardPrintScreen, keys: [Self.j])
        }
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        try controller.edit(.globalClipboardPrintScreen, keys: [Self.j], takeConflicts: true)
        #expect(controller.snapshot.keys(for: .globalClipboardOpen).isEmpty)
        #expect(controller.snapshot.keys(for: .globalClipboardPrintScreen) == [Self.j])
        #expect(backend.calls == ["register:38"])
        let transferredCombo = try #require(KeyCombo(Self.j))
        backend.hotKeys.handle(try #require(backend.ids[transferredCombo]))
        #expect(backend.calls == ["register:38", "activate", "printScreen"])
    }

    @Test("ローカルの既定キーは奪わずローカル操作の編集も拒否する")
    func localBoundary() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        #expect(throws: ShortcutController.EditError.self) {
            try controller.edit(
                .globalClipboardOpen, keys: [.init(key: .macVirtualKey(35), modifiers: .command)], takeConflicts: true)
        }
        #expect(throws: ShortcutController.EditError.self) { try controller.edit(.documentPrint, keys: []) }
        #expect(controller.snapshot.keys(for: .documentPrint) == [.init(key: .character("p"), modifiers: .command)])
        #expect(backend.calls.isEmpty)
    }

    @Test("編集直前にOS予約を再取得し変更された予約を拒否する")
    func editRefreshesReservations() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        var reserved: [ShortcutSystemReservation] = []
        var reads = 0
        let controller = controller(
            backend,
            reservations: {
                reads += 1
                return reserved
            })
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        _ = try controller.proposal(.globalClipboardOpen, keys: [Self.j])
        reserved = [.init(combination: Self.j)]
        #expect(throws: ShortcutModelError.self) { try controller.edit(.globalClipboardOpen, keys: [Self.j]) }
        #expect(reads == 3)
        #expect(backend.calls.isEmpty)
    }

    @Test("再有効化で予約された保存キーは保存を残して登録だけを外す")
    func activationReservation() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        var reserved: [ShortcutSystemReservation] = []
        let controller = controller(backend, reservations: { reserved })
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        try controller.edit(.globalClipboardOpen, keys: [Self.j])
        reserved = [.init(combination: Self.j)]
        controller.refresh()
        #expect(!backend.hotKeys.isRegistered(.open))
        #expect(controller.snapshot.keys(for: .globalClipboardOpen) == [Self.j])
        #expect(
            controller.unavailableBindings.contains {
                $0.operation == .globalClipboardOpen && $0.code == .systemReserved
            })
        #expect(backend.calls == ["register:38", "release:38"])
    }

    @Test("保存済みキーが登録できなくてもほかのキーは登録し保存は残す")
    func savedRegistrationFailure() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let configuration = ShortcutConfiguration(overrides: [
            .globalClipboardOpen: [Self.j], .globalClipboardPrintScreen: [Self.k],
        ])
        let data = try ShortcutStore.encode(configuration)
        suite.defaults.set(data, forKey: "keyboardShortcuts.v1")
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        backend.fail.insert(try #require(KeyCombo(Self.j)))
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        #expect(!backend.hotKeys.isRegistered(.open))
        #expect(backend.hotKeys.isRegistered(.printScreen))
        #expect(controller.snapshot == configuration)
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == data)
    }

    @Test("解除と既定復元では旧保存キーを復活させない")
    func clearAndRestore() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let controller = controller(backend)
        controller.start(preferences: preferences)
        try controller.edit(.globalClipboardOpen, keys: [])
        #expect(controller.snapshot.overrides[.globalClipboardOpen] == [])
        try controller.edit(.globalClipboardOpen, keys: nil)
        #expect(controller.snapshot.overrides[.globalClipboardOpen] == nil)
        controller.refresh()
        #expect(controller.snapshot.keys(for: .globalClipboardOpen).isEmpty)
        #expect(backend.calls == ["register:38", "release:38"])
    }

    @Test("破損ストアは旧キーに戻らず登録も保存もしない")
    func unreadableStore() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(Data("broken".utf8), forKey: "keyboardShortcuts.v1")
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        let backend = Backend()
        let controller = controller(backend)
        controller.start(preferences: preferences)
        #expect(controller.loadError)
        #expect(backend.calls.isEmpty)
        #expect(throws: ShortcutController.EditError.self) { try controller.edit(.globalClipboardOpen, keys: []) }
        #expect(suite.defaults.data(forKey: "keyboardShortcuts.v1") == Data("broken".utf8))
    }

    @Test("OS予約の取得失敗時は移行保存と登録を行わない")
    func unavailableEnvironment() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        let backend = Backend()
        let controller = controller(backend, reservations: { nil })
        controller.start(preferences: preferences)
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
        #expect(controller.migrationError != nil)
        #expect(backend.calls.isEmpty)
    }

    @Test("配列投影はShift付き記号と基底キーを両方持ち画面撮影キーを拒否する")
    func shiftedProjection() {
        let context = ShortcutValidationContext(projection: Self.layout.projection)
        let chord = ShortcutCombination(key: .macVirtualKey(20), modifiers: [.shift, .command])
        #expect(context.matches(.init(key: .character("#"), modifiers: .command), chord))
        #expect(context.matches(.init(key: .character("3"), modifiers: [.shift, .command]), chord))
        #expect(
            ShortcutValidator(environment: context).issues(for: .globalClipboardOpen, combination: chord).first?.code
                == .screenCapture)
    }

    @Test("記録中と解除済みIDでは実行せず復帰後は注入した窓口だけを呼ぶ")
    func recordingDelivery() throws {
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let combo = try #require(KeyCombo(Self.k))
        try backend.hotKeys.apply([combo: .printScreen])
        let oldID = try #require(backend.ids[combo])
        backend.hotKeys.beginRecording()
        backend.hotKeys.handle(oldID)
        backend.hotKeys.endRecording()
        backend.hotKeys.handle(oldID)
        #expect(!backend.calls.contains("activate"))
        backend.hotKeys.handle(try #require(backend.ids[combo]))
        #expect(backend.calls.suffix(2) == ["activate", "printScreen"])
    }

    @Test("確認後に設定が変わった場合は古い確認でキーを奪わない")
    func staleReview() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        let controller = controller(backend)
        controller.start(preferences: AppPreferences(defaults: suite.defaults))
        let reviewed = controller.snapshot
        try controller.edit(.globalClipboardPrintScreen, keys: [Self.j])
        #expect(throws: ShortcutPreferencesError.self) {
            try controller.edit(.globalClipboardOpen, keys: [Self.j], takeConflicts: true, expectedSnapshot: reviewed)
        }
        #expect(controller.snapshot.keys(for: .globalClipboardPrintScreen) == [Self.j])
        #expect(controller.snapshot.keys(for: .globalClipboardOpen).isEmpty)
    }

    @Test("移行の登録中に旧データが変わった場合は登録を戻して保存しない")
    func migrationChangedDuringRegistration() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.openClipboardShortcut = KeyCombo(Self.j)
        let backend = Backend()
        defer { backend.hotKeys.stop() }
        backend.beforeRegister = { preferences.openClipboardShortcut = KeyCombo(Self.k) }
        let controller = controller(backend)
        controller.start(preferences: preferences)
        #expect(backend.calls == ["register:38", "release:38"])
        #expect(!backend.hotKeys.isRegistered(.open))
        #expect(suite.defaults.object(forKey: "keyboardShortcuts.v1") == nil)
    }

    @Test("複数キーの途中で登録に失敗すると確保したキーだけを解放する")
    func batchRollback() throws {
        var count = 0
        var released: [UInt32] = []
        let keys = GlobalHotKeys(
            register: { combo, _ in
                count += 1
                if count == 2 { return nil }
                return { released.append(combo.keyCode) }
            }, activate: { Issue.record("実行しない") }, openClipboard: { _ in Issue.record("実行しない") })
        defer { keys.stop() }
        let j = try #require(KeyCombo(Self.j))
        let k = try #require(KeyCombo(Self.k))
        var committed = false
        #expect(throws: GlobalHotKeys.RegistrationError.self) {
            try keys.apply([j: .open, k: .printScreen]) { committed = true }
        }
        #expect(!committed)
        #expect(count == 2)
        #expect(released.count == 1)
        #expect(keys.assignments.isEmpty)
    }

    private func event(code: UInt16, flags: NSEvent.ModifierFlags, text: String) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    @Test("記録は修飾なしのDeleteだけを解除し修飾不足のキーは検証へ渡す")
    func recorderCandidates() throws {
        let deletion = try event(code: 51, flags: [], text: "\u{7F}")
        #expect(try ShortcutRecorder.candidate(deletion) == nil)
        let forwardDeletion = try event(code: 117, flags: .function, text: "\u{F728}")
        #expect(try ShortcutRecorder.candidate(forwardDeletion) == nil)
        let modified = try event(code: 51, flags: .command, text: "\u{7F}")
        #expect(try ShortcutRecorder.candidate(modified) == KeyCombo(keyCode: 51, modifiers: UInt32(cmdKey)))
        let bare = try event(code: 38, flags: [], text: "j")
        let recorded = try ShortcutRecorder.candidate(bare)
        let candidate = try #require(recorded)
        let combination = try candidate.recordedShortcutCombination()
        let issues = ShortcutValidator(environment: .init(projection: Self.layout.projection))
            .issues(for: .globalClipboardOpen, combination: combination)
        #expect(issues.first?.code == .globalModifierRequired)
    }

    @Test("記録はデッドキーとFnの追加を拒否し通常の矢印とFキーは残す")
    func recorderFunctionAndDeadKeys() throws {
        let dead = try event(code: 14, flags: .option, text: "")
        let fnLetter = try event(code: 38, flags: [.function, .command], text: "j")
        let fnLeft = try event(code: 123, flags: [.function, .command], text: "\u{F729}")
        for event in [dead, fnLetter, fnLeft] {
            #expect(throws: ShortcutModelError.self) { try ShortcutRecorder.candidate(event) }
        }
        let arrow = try event(code: 123, flags: [.function, .command], text: "\u{F702}")
        let function = try event(code: 122, flags: [.function, .command], text: "\u{F704}")
        #expect(try ShortcutRecorder.candidate(arrow)?.keyCode == 123)
        #expect(try ShortcutRecorder.candidate(function)?.keyCode == 122)
    }
}
