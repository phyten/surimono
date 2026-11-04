import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct StreamingPreviewTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("SurimonoTests.streaming.\(UUID().uuidString)"))
    }

    private func windows(_ suite: TestDefaultsSuite, library: URL) -> StreamingPreviewWindows {
        let windows = StreamingPreviewWindows(closeWelcome: {})
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: library)
        return windows
    }

    private func settle(_ model: DocumentViewModel) async throws {
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("Marked と同じ名前のペーストボードを 0.5 秒ごとに見る")
    func contract() {
        #expect(StreamingPreviewWindows.pasteboardName.rawValue == "mkStreamingPreview")
        #expect(StreamingPreviewWindows.pollInterval == 0.5)
    }

    @Test("開いたときの文字を見せ、変わったらメモリ上の文書として組み直す", .timeLimit(.minutes(1)))
    func follows() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("# 一", forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = windows(suite, library: directory)
        let controller = windows.open(from: board)
        defer { controller.window?.close() }
        let model = controller.model
        model.start()
        #expect(model.memoryContent == Data("# 一".utf8))
        #expect(model.fileURL == nil)
        #expect(model.toast == nil)
        try await settle(model)
        board.clearContents()
        board.setString("# 二", forType: .string)
        windows.poll()
        #expect(model.memoryContent == Data("# 二".utf8))
        try await settle(model)
        #expect(model.result != nil)
        #expect(model.error == nil)
        board.clearContents()
        board.setString("<!doctype html><html><body>三</body></html>", forType: .string)
        windows.poll()
        #expect(model.format == .html)
    }

    @Test("組版の間に来た変更は読まずに残し、終わってから一番新しい文字を読む", .timeLimit(.minutes(1)))
    func waitsForLayout() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("# 一", forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = windows(suite, library: directory)
        let controller = windows.open(from: board)
        defer { controller.window?.close() }
        let model = controller.model
        model.start()
        #expect(model.isRendering)
        board.clearContents()
        board.setString("# 二", forType: .string)
        windows.poll()
        #expect(model.memoryContent == Data("# 一".utf8))
        try await settle(model)
        windows.poll()
        #expect(model.memoryContent == Data("# 二".utf8))
    }

    @Test("空のペーストボードでは待っていることを示し、書き手が消した瞬間は前の文字を残す", .timeLimit(.minutes(1)))
    func waiting() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = windows(suite, library: directory)
        let controller = windows.open(from: board)
        defer { controller.window?.close() }
        let model = controller.model
        #expect(model.toast != nil)
        #expect(!model.canSaveAsFile)
        try await settle(model)
        board.clearContents()
        board.setString("本文", forType: .string)
        windows.poll()
        #expect(model.toast == nil)
        #expect(model.canSaveAsFile)
        try await settle(model)
        board.clearContents()
        windows.poll()
        #expect(model.memoryContent == Data("本文".utf8))
    }

    @Test("書き手が消してから書くあいだに見ても、本文を取り逃さない", .timeLimit(.minutes(1)))
    func pollBetweenClearAndWrite() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("# 一", forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = windows(suite, library: directory)
        let controller = windows.open(from: board)
        defer { controller.window?.close() }
        let model = controller.model
        try await settle(model)
        board.clearContents()
        windows.poll()
        #expect(model.memoryContent == Data("# 一".utf8))
        board.setString("# 二", forType: .string)
        windows.poll()
        #expect(model.memoryContent == Data("# 二".utf8))
    }

    @Test("窓は一つで、閉じると監視をやめて変更を読まない", .timeLimit(.minutes(1)))
    func watchesWhileOpen() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = windows(suite, library: directory)
        #expect(!windows.isWatching)
        let controller = windows.open(from: board)
        #expect(windows.isWatching)
        #expect(windows.hasWindow)
        #expect(windows.open(from: board) === controller)
        controller.window?.close()
        #expect(!windows.isWatching)
        #expect(!windows.hasWindow)
        board.setString("閉じたあと", forType: .string)
        windows.poll()
        #expect(controller.model.memoryContent?.isEmpty == true)
    }

    @Test("ファイルから開いた文書の中身は差し替えない")
    func fileDocumentsStay() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data("# 元".utf8), fileURL: URL(fileURLWithPath: "/fixtures/a.md"), format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        defer { model.stop() }
        model.replaceContent(Data("# 別".utf8), format: .markdown)
        #expect(model.memoryContent == nil)
        #expect(model.themedSource?.data == Data("# 元".utf8))
    }

    @Test("ファイルメニューにストリーミングプレビューがある")
    func menu() {
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        #expect(items.contains { $0.title == String(localized: "Streaming Preview") })
    }

    @Test("消した直後に開いても、そのあと書かれた本文を受け取る", .timeLimit(.minutes(1)))
    func textAfterClearing() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let board = NSPasteboard(name: NSPasteboard.Name("surimono-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let windows = StreamingPreviewWindows(closeWelcome: {})
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: library)
        let controller = windows.open(from: board)
        defer { controller.close() }
        // Writing after clearing does not change the count again.
        board.setString("# 後から書いた本文", forType: .string)
        try await settle(controller.model)
        windows.poll()
        try await settle(controller.model)
        #expect(controller.model.memoryContent == Data("# 後から書いた本文".utf8))
    }
}
