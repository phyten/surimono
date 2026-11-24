import Darwin
import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ClosedClipboardStoreTests {
    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var directory: URL { root.appendingPathComponent("ClosedClipboard", isDirectory: true) }
        let suite = TestDefaultsSuite()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func launch() -> AppPreferences {
            AppPreferences(defaults: suite.defaults, clipboardDirectory: directory, clipboardNow: { self.now })
        }

        func remember(_ title: String, in preferences: AppPreferences) -> ClosedClipboardDocuments.Entry {
            let bytes = Data(title.utf8)
            let model = DocumentViewModel(
                data: bytes, fileURL: nil, format: .html, preferences: preferences, library: UserLibrary(root: root),
                title: title, htmlBaseURL: URL(string: "https://fixture.invalid/example/"))
            model.textFormatOrigin = .chosen
            model.layoutID = PrintLayout.a4Duplex.id
            model.mode = .print
            model.currentPageIndex = 4
            model.isAlwaysOnTop = true
            model.showsOnAllSpaces = true
            model.copies = 7
            model.selectedSettingSetID = UUID()
            let entry = ClosedClipboardDocuments.Entry(model: model, hash: .of(bytes), data: bytes, date: now)
            preferences.closedClipboardDocuments.remember(entry)
            return entry
        }

        func clean() {
            try? FileManager.default.removeItem(at: root)
            suite.remove()
        }

        func files() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        }
    }

    @Test("閉じた文書の全項目を復元し、保存する前からディレクトリと文書を非公開にする")
    func roundTrip() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let prefs = fixture.launch()
        let original = fixture.remember("記事", in: prefs)
        #expect(!prefs.keepsClipboardAfterQuitting)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        prefs.keepsClipboardAfterQuitting = true
        let file = try #require(try fixture.files().first)
        for (url, mode) in [(fixture.directory, 0o700), (file, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == mode)
            // A restricted test host can write the exclusion but cannot query the backup service.
            if try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
                let key = "com.apple.metadata:com_apple_backup_excludeItem"
                let size = getxattr(url.path, key, nil, 0, 0, 0)
                try #require(size > 0)
                var data = Data(count: size)
                let count = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, 0) }
                try #require(count == size)
                #expect(try PropertyListDecoder().decode(String.self, from: data) == "com.apple.backupd")
            }
        }
        let restored = try #require(fixture.launch().closedClipboardDocuments.entries.first)
        #expect(restored.menuItem == original.menuItem)
        #expect(restored.data == Data("記事".utf8))
        #expect(restored.title == "記事")
        #expect(restored.format == .html)
        #expect(restored.origin == .chosen)
        #expect(restored.baseURL?.absoluteString == "https://fixture.invalid/example/")
        #expect(restored.settings == original.settings)
        #expect(restored.page == 4)
        #expect(restored.wasPrinting && restored.alwaysOnTop && restored.allSpaces)
        #expect(restored.copies == 7)
        #expect(restored.settingSet == original.settingSet)
        #expect(restored.closedAt == fixture.now)
    }

    @Test("起動時に期限に達した文書・未知の版・壊れたファイルを消し、期限直前の文書を残す")
    func expiresAndDropsInvalidRecords() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let prefs = fixture.launch()
        prefs.keepsClipboardAfterQuitting = true
        _ = fixture.remember("期限到達", in: prefs)
        fixture.now.addTimeInterval(1)
        let valid = fixture.remember("期限直前", in: prefs)
        let unknown = fixture.remember("未知の版", in: prefs)
        let url = fixture.directory.appendingPathComponent(unknown.menuItem.id.hex + ".json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try Data([0xFF]).write(to: fixture.directory.appendingPathComponent("broken.json"))
        fixture.now.addTimeInterval(7 * 86400 - 1)
        #expect(fixture.launch().closedClipboardDocuments.entries.map(\.title) == ["期限直前"])
        #expect(try fixture.files().map(\.lastPathComponent) == [valid.menuItem.id.hex + ".json"])
    }

    @Test("追加・件数と容量による除外・取り出しを保存し、復元した順序でメニューを作る")
    func mirrorsChanges() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let prefs = fixture.launch()
        prefs.closedClipboardDocuments = ClosedClipboardDocuments(byteLimit: 20)
        prefs.keepsClipboardAfterQuitting = true
        for index in 0..<12 { _ = fixture.remember(String(index), in: prefs) }
        #expect(try fixture.files().count == 10)
        let newest = fixture.remember("012345678901234567", in: prefs)
        let loaded = fixture.launch()
        let history = MenuSnapshot.Content(preferences: loaded).history
        #expect(history.map(\.id) == [newest.menuItem.id, .of(Data("11".utf8))])
        loaded.closedClipboardDocuments.remove(newest.menuItem.id)
        #expect(fixture.launch().closedClipboardDocuments.entries.map(\.title) == ["11"])
        DocumentMenuAction.clearClipboard.perform(preferences: loaded)
        DocumentMenuAction.clearClipboard.perform(preferences: loaded)
        #expect(loaded.closedClipboardDocuments.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("保存した履歴は再起動時に窓を開かず、メニューや再貼り付けで開くと記録が消える")
    func reopenPersisted() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let windows = ClipboardWindows(openFiles: { _, _, _ in }, warn: { _ in }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        windows.library = UserLibrary(root: fixture.root)
        let prefs = fixture.launch()
        prefs.keepsClipboardAfterQuitting = true
        windows.preferences = prefs
        let bytes = Data("menu fixture".utf8)
        windows.open(bytes, format: .plainText, title: "Fixture", textOrigin: .chosen).close()
        windows.preferences = fixture.launch()
        #expect(!windows.hasWindows)
        let reopened = try #require(windows.reopenClosed(.of(bytes)))
        let reopenedModel = try #require(reopened.model)
        #expect(reopenedModel.textFormatOrigin == .chosen)
        #expect(fixture.launch().closedClipboardDocuments.entries.isEmpty)
        reopened.close()
        #expect(fixture.launch().closedClipboardDocuments.entries.count == 1)
        let pasted = windows.open(bytes, format: .plainText, title: "Fixture")
        defer { pasted.close() }
        #expect(fixture.launch().closedClipboardDocuments.entries.isEmpty)
    }

    @Test("同じ内容を閉じ直すと設定と期限を更新し、ファイルは一件だけ残す")
    func replacesRecord() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let prefs = fixture.launch()
        prefs.keepsClipboardAfterQuitting = true
        _ = fixture.remember("同じ内容", in: prefs)
        fixture.now.addTimeInterval(3 * 86400)
        let latest = fixture.remember("同じ内容", in: prefs)
        fixture.now.addTimeInterval(4 * 86400)
        let loaded = try #require(fixture.launch().closedClipboardDocuments.entries.first)
        #expect(loaded.settingSet == latest.settingSet)
        #expect(loaded.closedAt == latest.closedAt)
        #expect(try fixture.files().count == 1)
    }

    @Test("保存を切るとディスクだけを消し、終了までの保持を切るとメモリの履歴も消す")
    func disablingRetention() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let prefs = fixture.launch()
        prefs.keepsClipboardAfterQuitting = true
        _ = fixture.remember("一件目", in: prefs)
        prefs.keepsClipboardAfterQuitting = false
        #expect(prefs.closedClipboardDocuments.entries.count == 1)
        _ = fixture.remember("二件目", in: prefs)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        prefs.keepsClipboardAfterQuitting = true
        #expect(try fixture.files().count == 2)
        prefs.keepsClosedClipboardDocuments = false
        #expect(prefs.closedClipboardDocuments.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data([1]).write(to: fixture.directory.appendingPathComponent("leftover.json"))
        #expect(fixture.launch().closedClipboardDocuments.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }
}
