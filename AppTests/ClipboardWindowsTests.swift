import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ClipboardWindowsTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("SurimonoTests.clipboard.\(UUID().uuidString)"))
    }

    @Test("専用ペーストボードの文字列をファイルなしのウィンドウで開き同じ内容は再利用する", .timeLimit(.minutes(1)))
    func opensAndReuses() throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("# Clipboard test", forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in
                Issue.record("警告しない")
            }, closeWelcome: {})
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory)
        let recent = NSDocumentController.shared.recentDocumentURLs
        let documents = NSDocumentController.shared.documents.count
        let first = try #require(windows.open(from: board))
        defer { first.window?.close() }
        #expect(first.model.format == .markdown)
        #expect(first.model.fileURL == nil)
        #expect(first.model.sourceURLs.isEmpty)
        #expect(first.model.displayName == first.window?.title)
        #expect(first.model.exportName.hasPrefix(first.model.displayName.replacingOccurrences(of: ":", with: "-")))
        #expect(windows.hasWindows)
        let router = OpenRouter(
            openDocument: { _, _ in }, openBundle: { _, _ in }, openBinder: { _, _ in Issue.record("合本は開かない") },
            warn: { _ in },
            hasOpenWindows: { windows.hasWindows }, showWelcome: { Issue.record("窓があるのでウェルカム画面は出さない") })
        router.showWelcomeIfIdle()
        first.window?.orderOut(nil)
        let second = try #require(windows.open(from: board))
        #expect(first === second)
        #expect(second.window?.isVisible == true)
        #expect(NSDocumentController.shared.documents.count == documents)
        #expect(NSDocumentController.shared.recentDocumentURLs == recent)
        board.clearContents()
        board.setString("別の内容", forType: .string)
        let different = try #require(windows.open(from: board))
        defer { different.window?.close() }
        #expect(different !== first)
        first.window?.close()
        #expect(windows.hasWindows)
        different.window?.close()
        #expect(!windows.hasWindows)
        board.clearContents()
        board.setString("# Clipboard test", forType: .string)
        let reopened = try #require(windows.open(from: board))
        defer { reopened.window?.close() }
        #expect(reopened !== first)
    }

    @Test("空のペーストボードとHTMLだけの場合は対象ウィンドウに警告する")
    func warns() {
        let board = board()
        defer { board.releaseGlobally() }
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var warnings = 0
        let windows = ClipboardWindows(
            openFiles: { _, _ in Issue.record("開かない") },
            warn: { window in
                #expect(window === parent)
                warnings += 1
            }, closeWelcome: {})
        #expect(windows.open(from: board, window: parent) == nil)
        board.setString("<p>Rich text</p>", forType: .html)
        #expect(windows.open(from: board, window: parent) == nil)
        #expect(warnings == 2)
        #expect(!windows.hasWindows)
    }

    @Test("FinderのファイルURLは文字列より優先して既存のルーターにまとめて渡す")
    func routesFiles() {
        let board = board()
        defer { board.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/fixtures/2.png"), URL(fileURLWithPath: "/fixtures/1.jpg")]
        board.writeObjects(urls as [NSURL])
        board.setString("# ファイルを優先", forType: .string)
        var opened: [URL] = []
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("単独では開かない") },
            openBundle: { urls, excluded in
                opened = urls
                #expect(excluded.isEmpty)
            },
            openBinder: { _, _ in Issue.record("合本は開かない") }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { false }, showWelcome: {})
        let windows = ClipboardWindows(
            openFiles: { urls, window in router.open(urls, from: window) },
            warn: { _ in
                Issue.record("警告しない")
            }, closeWelcome: {})
        #expect(windows.open(from: board) == nil)
        #expect(opened == [urls[1], urls[0]])
        #expect(!windows.hasWindows)
    }

    @Test("PNGとTIFFを読み取り文字列があればそちらを優先する")
    func readsImages() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let png = TestFixtures.png(red: 1)
        board.setData(png, forType: .png)
        #expect(ClipboardWindows.content(from: board) == .document(data: png, format: .image))
        board.clearContents()
        let tiff = try #require(NSImage(data: png)?.tiffRepresentation)
        board.setData(tiff, forType: .tiff)
        #expect(ClipboardWindows.content(from: board) == .document(data: tiff, format: .image))
        board.setString("本文", forType: .string)
        #expect(ClipboardWindows.content(from: board) == .document(data: Data("本文".utf8), format: .plainText))
    }

    @Test("URLのない文書の再読み込みはファイルを読まずエラーも出さない", .timeLimit(.minutes(1)))
    func reloadWithoutFile() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: TestFixtures.png(red: 0.75), fileURL: nil, format: .image,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            title: "Clipboard 0:13")
        defer { model.stop() }
        model.readReloadData = { _ in
            Issue.record("ファイルを読まない")
            return Data()
        }
        model.reload()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.result != nil)
        #expect(model.toast == nil)
        #expect(!model.isRendering)
        #expect(model.displayName == "Clipboard 0:13")
        #expect(model.exportName.hasPrefix("Clipboard 0-13（"))
        #expect(
            DocumentViewModel.exportName(
                fileURL: URL(fileURLWithPath: "/fixtures/note.md"),
                layout: .a4Single, language: "en") == "note（A4 Single-sided）.pdf")
    }

    @Test("クリップボードの画像は組版して刷り台からPDFにでき設定を内容ごとに復元する", .timeLimit(.minutes(1)))
    func imageOutputAndSettings() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let png = TestFixtures.png(red: 0.25)
        board.setData(png, forType: .png)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in
                Issue.record("警告しない")
            }, closeWelcome: {})
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory.appendingPathComponent("Library"))
        windows.settingsStore = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        let first = try #require(windows.open(from: board))
        defer { first.window?.close() }
        first.model.start()
        for _ in 0..<500 where first.model.contentHash == nil || first.model.result == nil || first.model.isRendering {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.model.contentHash == ContentHash.of(png))
        #expect(first.model.result != nil)
        first.model.layoutID = PrintLayout.a4Duplex.id
        first.model.rememberedSettingsDidChange()
        first.model.performPrintCommand()
        #expect(first.model.mode == .print)
        first.model.render()
        for _ in 0..<500 where first.model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(first.model.canOutput)
        #expect(first.model.printResult?.sheetDocument.dataRepresentation() != nil)
        first.window?.close()
        let reopened = try #require(windows.open(from: board))
        defer { reopened.window?.close() }
        reopened.model.start()
        for _ in 0..<500 where reopened.model.contentHash == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(reopened.model.hasSavedSettings)
        #expect(reopened.model.layoutID == "a4Duplex")
    }

    @Test("ファイルメニューのコマンドNはクリップボードから開く一つだけ")
    func menu() throws {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let matches = items.filter { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }
        #expect(matches.count == 1)
        let item = try #require(matches.first)
        #expect(item.title == String(localized: "Open from Clipboard"))
        #expect(item.action != #selector(NSDocumentController.newDocument(_:)))
    }
}
