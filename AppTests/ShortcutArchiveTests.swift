import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import Surimono

/// Only a volatile domain is used; no test preferences are written to Library/Preferences.
private final class ShortcutMemoryDefaults: UserDefaults, @unchecked Sendable {
    // UserDefaults synchronizes access to volatile domains. There is no additional mutable state.
    private let domain = "ShortcutArchiveTests." + UUID().uuidString
    override func object(forKey key: String) -> Any? { volatileDomain(forName: domain)[key] }
    override func set(_ value: Any?, forKey key: String) {
        var values = volatileDomain(forName: domain)
        values[key] = value
        setVolatileDomain(values, forName: domain)
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
}

@MainActor
struct ShortcutArchiveAppTests {
    @MainActor
    private final class Fixture {
        let defaults = ShortcutMemoryDefaults()
        var registrations = 0
        var releases = 0
        var fail = false
        var reserved: [ShortcutSystemReservation] = []
        lazy var hotKeys = GlobalHotKeys(
            register: { [self] _, _ in
                registrations += 1
                if fail { return nil }
                return { self.releases += 1 }
            }, activate: { Issue.record("起動しない") }, openClipboard: { _ in Issue.record("文書を開かない") })
        lazy var controller = ShortcutController(
            hotKeys: hotKeys, reservations: { self.reserved },
            keyboardLayout: { ShortcutKeyboardLayout.project { code, _ in code == 38 ? "j" : code == 40 ? "k" : nil } })
        func start() { controller.start(preferences: AppPreferences(defaults: defaults)) }
    }

    private let global = ShortcutCombination(key: .macVirtualKey(38), modifiers: [.command, .control, .option])
    private let local = ShortcutCombination(key: .character("x"), modifiers: [.command, .control])

    @Test("読み込みのレビューと取消は保存もグローバル登録もしない")
    func cancellation() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        let before = f.defaults.data(forKey: "keyboardShortcuts.v1")
        let data = try ShortcutArchive(configuration: .init(overrides: [.globalClipboardOpen: [global]])).encode()
        _ = try f.controller.importReview(data)
        #expect(f.registrations == 0)
        #expect(f.defaults.data(forKey: "keyboardShortcuts.v1") == before)
        #expect(f.controller.snapshot.keys(for: .globalClipboardOpen).isEmpty)
    }

    @Test("確定前のグローバル登録と印刷キーの無確認適用を拒否する")
    func acknowledgement() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        let review = ShortcutImportReview(
            archive: ShortcutArchive(
                configuration: .init(overrides: [
                    .globalClipboardOpen: [global], .documentPrint: [local],
                ])), original: f.controller.snapshot)
        #expect(throws: ShortcutController.EditError.acknowledgementRequired) {
            try f.controller.applyImport(review, acknowledged: false)
        }
        #expect(
            ShortcutController.message(ShortcutController.EditError.acknowledgementRequired)
                == String(localized: "Acknowledge the global and printing shortcut changes before applying."))
        #expect(f.registrations == 0)
        try f.controller.applyImport(review, acknowledged: true)
        #expect(f.registrations == 1)
        #expect(f.controller.snapshot.keys(for: .documentPrint) == [local])
    }

    @Test("登録失敗では統合したローカル変更も保存も取り消す")
    func registrationFailure() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        let previous = ShortcutCombination(key: .macVirtualKey(40), modifiers: [.command, .control, .option])
        try f.controller.edit(.globalClipboardPrintScreen, keys: [previous])
        let original = f.controller.snapshot
        let saved = f.defaults.data(forKey: "keyboardShortcuts.v1")
        let review = ShortcutImportReview(
            archive: ShortcutArchive(
                configuration: .init(overrides: [
                    .globalClipboardOpen: [global], .documentReload: [local],
                ])), original: original)
        f.fail = true
        #expect(throws: GlobalHotKeys.RegistrationError.self) {
            try f.controller.applyImport(review, acknowledged: true)
        }
        #expect(f.controller.snapshot == original)
        #expect(f.defaults.data(forKey: "keyboardShortcuts.v1") == saved)
        #expect(f.controller.snapshot.keys(for: .globalClipboardPrintScreen) == [previous])
        #expect(f.hotKeys.isRegistered(.printScreen))
        #expect(f.releases == 0)
    }

    @Test("レビュー後の予約変更と古いスナップショットを拒否する")
    func revalidation() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        let review = ShortcutImportReview(
            archive: ShortcutArchive(configuration: .init(overrides: [.documentReload: [local]])),
            original: f.controller.snapshot)
        f.reserved = [.init(combination: local)]
        #expect(throws: ShortcutModelError.self) { try f.controller.applyImport(review, acknowledged: true) }
        f.reserved = []
        try f.controller.edit(.documentFind, keys: [])
        #expect(throws: ShortcutPreferencesError.self) { try f.controller.applyImport(review, acknowledged: true) }
    }

    @Test("全件復元はグローバルを解除しmacOSの割当を残す")
    func restore() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        #expect(!f.controller.canRestoreAll)
        try f.controller.edit(.globalClipboardOpen, keys: [global])
        try f.controller.edit(.documentReload, keys: [local])
        #expect(f.controller.canRestoreAll)
        let external = ShortcutCombination(key: .character("y"), modifiers: [.command, .control])
        f.controller.setExternalMenuKeys([.documentFind: external])
        try f.controller.restoreAll(expectedSnapshot: f.controller.snapshot)
        #expect(f.controller.snapshot.overrides.isEmpty)
        #expect(!f.controller.canRestoreAll)
        #expect(f.controller.localKeys(for: .documentFind) == [external])
        #expect(f.releases == 1)
    }

    @Test("ヒントは変更・解除とmacOSの割当に追従し固定キーを残す")
    func hints() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        try f.controller.edit(.documentReload, keys: [local])
        #expect(KeyGuideEntry.reload.trigger(controller: f.controller) == "⌃⌘X")
        #expect(ShortcutHints.help("Reload", [.documentReload], controller: f.controller).contains("⌃⌘X"))
        try f.controller.edit(.documentReload, keys: [])
        #expect(KeyGuideEntry.reload.trigger(controller: f.controller) == String(localized: "Unassigned"))
        #expect(ShortcutHints.help("Reload", [.documentReload], controller: f.controller) == "Reload")
        f.controller.setExternalMenuKeys([.documentReload: local])
        #expect(KeyGuideEntry.reload.trigger(controller: f.controller) == "⌃⌘X")
        #expect(KeyGuideEntry.escape.trigger(controller: f.controller) == "Esc")
    }

    @Test("複数操作のガイドは残ったキーを示し全解除のときだけ未割当になる")
    func partiallyAssignedGuide() throws {
        let f = Fixture()
        f.start()
        defer { f.hotKeys.stop() }
        try f.controller.edit(.documentFindNext, keys: [])
        #expect(KeyGuideEntry.findStep.trigger(controller: f.controller) == "⇧⌘G")
        try f.controller.edit(.documentFindPrevious, keys: [])
        #expect(KeyGuideEntry.findStep.trigger(controller: f.controller) == String(localized: "Unassigned"))
        #expect(
            ShortcutHints.help("Find", [.documentFindNext, .documentFindPrevious], controller: f.controller) == "Find")
    }

    @Test("無効な移行記録だけ残るときも全件復元を選べる")
    func restoreInactiveMigration() throws {
        let f = Fixture()
        let configuration = ShortcutConfiguration(inactiveMigration: [
            .init(operation: .globalClipboardOpen, legacyData: nil, candidate: nil, reasons: [.invalidKey])
        ])
        f.defaults.set(try ShortcutStore.encode(configuration), forKey: ShortcutStore.preferencesKey)
        f.start()
        defer { f.hotKeys.stop() }
        #expect(f.controller.canRestoreAll)
        try f.controller.restoreAll(expectedSnapshot: f.controller.snapshot)
        #expect(!f.controller.canRestoreAll)
    }

    @Test("同じ配置カードでも大きい用紙と小さい用紙と4ページ配置のキーを区別する")
    func layoutHints() {
        for layout in [PrintLayout.a3TwoUp, .b4TwoUp, .tabloidTwoUp] {
            #expect(ShortcutHints.layout(layout, index: 4, compact: true) == .printLayoutTwoUpLarge)
        }
        for layout in [PrintLayout.a4TwoUp, .b5TwoUp, .letterTwoUp] {
            #expect(ShortcutHints.layout(layout, index: 4, compact: true) == .printLayoutTwoUpSmall)
        }
        for layout in [PrintLayout.a4FourUp, .b5FourUp, .letterFourUp] {
            #expect(ShortcutHints.layout(layout, index: 4, compact: true) == .printLayoutFourUp)
        }
    }

    @Test("ファイルパネルの取消はファイルも設定も変えない")
    func panelCancellation() {
        let files = ShortcutArchiveFiles(open: { $0(nil) }, save: { $0(nil) }, protectedURLs: { [] })
        var imports = 0
        var exports = 0
        files.importFile {
            #expect($0 == nil)
            imports += 1
        }
        files.exportFile(.init()) {
            #expect($0 == nil)
            exports += 1
        }
        #expect(imports == 1)
        #expect(exports == 1)
    }

    @Test("書き出しは指定した一時ファイルにだけ行い読み込みと往復する")
    func panels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("shortcuts.json")
        let configuration = ShortcutConfiguration(overrides: [.documentReload: [local]])
        let files = ShortcutArchiveFiles(open: { $0(url) }, save: { $0(url) }, protectedURLs: { [] })
        var exported = false
        files.exportFile(configuration) { if case .success = $0 { exported = true } }
        #expect(exported)
        var received: Data?
        files.importFile { if case .success(let data) = $0 { received = data } }
        #expect(try ShortcutArchive.decode(#require(received)) == ShortcutArchive(configuration: configuration))
        let protected = ShortcutArchiveFiles(open: { $0(url) }, save: { $0(url) }, protectedURLs: { [url] })
        var refused = false
        protected.exportFile(.init()) { if case .failure = $0 { refused = true } }
        #expect(refused)
        #expect(try Data(contentsOf: url) == received)
    }
}
