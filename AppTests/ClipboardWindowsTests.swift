import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ClipboardWindowsTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("SurimonoTests.clipboard.\(UUID().uuidString)"))
    }

    /// Markdown the detector opens without asking.
    private static let markdown = "# Clipboard test\n\nSome **bold** text.\n\n## Section\n\n- one\n- two\n- three\n"

    @Test("クリップボードの文章を刷り台で開く要求は同じ窓へ届く", .timeLimit(.minutes(1)))
    func opensOnPrintScreen() throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString(Self.markdown, forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in Issue.record("警告しない") }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory)
        let controller = try #require(windows.open(from: board, window: nil))
        defer { controller.window?.close() }
        #expect(!controller.model.isPrintModeRequested)
        let printing = windows.open(from: board, window: nil, printing: true)
        #expect(printing === controller)
        #expect(controller.model.isPrintModeRequested || controller.model.mode == .print)
    }

    @Test("専用ペーストボードの文字列をファイルなしのウィンドウで開き同じ内容は再利用する", .timeLimit(.minutes(1)))
    func opensAndReuses() throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString(Self.markdown, forType: .string)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = ClipboardWindows(
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in
                Issue.record("警告しない")
            }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows, ordered: true)
        defer { presentation.close() }
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
            openDocument: { _, _ in }, openBundle: { _, _ in nil },
            openBinder: { _, _ in
                Issue.record("合本は開かない")
                return nil
            },
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
        board.setString(Self.markdown, forType: .string)
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
            openFiles: { _, _, _ in Issue.record("開かない") },
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
                return nil
            },
            openBinder: { _, _ in
                Issue.record("合本は開かない")
                return nil
            }, warn: { _ in Issue.record("警告しない") },
            hasOpenWindows: { false }, showWelcome: {})
        let windows = ClipboardWindows(
            openFiles: { urls, window, printing in router.open(urls, from: window, printing: printing) },
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
        #expect(ClipboardWindows.content(from: board) == .text("本文", hints: .init()))
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
            openFiles: { _, _, _ in Issue.record("ファイルは開かない") },
            warn: { _ in
                Issue.record("警告しない")
            }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        windows.preferences = AppPreferences(defaults: suite.defaults)
        windows.library = UserLibrary(root: directory.appendingPathComponent("Library"))
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
        #expect(reopened.model.settingsStore == nil)
        #expect(reopened.model.hasSavedSettings)
        #expect(reopened.model.layoutID == "a4Duplex")
    }

    @Test("閉じた URL 文書を元の表題・基準 URL・紙面設定で開き直し、既に開いていればその窓を使う")
    func restoresClosed() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let prefs = AppPreferences(defaults: suite.defaults)
        let windows = ClipboardWindows(openFiles: { _, _, _ in }, warn: { _ in }, closeWelcome: {})
        let presentation = ClipboardWindowFixture(windows)
        defer { presentation.close() }
        windows.preferences = prefs
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        windows.library = UserLibrary(root: root)
        let bytes = Data("<p>Article</p>".utf8)
        let base = URL(string: "https://fixture.invalid/news/article")!
        let first = windows.open(bytes, format: .html, title: "Article", baseURL: base)
        first.model.setSmartRemoval(enabled: true)
        first.model.layoutID = PrintLayout.a4Duplex.id
        first.model.copies = 3
        first.close()
        #expect(prefs.closedClipboardDocuments.entries.count == 1)
        #expect(AppPreferences(defaults: suite.defaults).closedClipboardDocuments.entries.isEmpty)
        let reopened = try #require(windows.reopenClosed())
        defer { reopened.close() }
        #expect(reopened !== first)
        #expect(prefs.closedClipboardDocuments.entries.isEmpty)
        #expect(reopened.model.memoryContent == bytes)
        #expect(reopened.model.settingsStore == nil)
        #expect(reopened.model.displayName == "Article")
        #expect(reopened.model.format == .html)
        #expect(reopened.model.htmlPresentation == .paper)
        #expect(!reopened.model.usesHTMLPresentation)
        #expect(reopened.model.htmlBaseURL == base)
        #expect(reopened.model.isSmartRemovalEnabled)
        #expect(reopened.model.layoutID == PrintLayout.a4Duplex.id)
        #expect(reopened.model.copies == 3)
        reopened.close()
        let open = windows.open(bytes, format: .html, title: "Already open", baseURL: base)
        defer { open.close() }
        #expect(windows.reopenClosed() === open)
        open.close()
        prefs.keepsClosedClipboardDocuments = false
        #expect(windows.reopenClosed() == nil)
        windows.open(bytes, format: .html, title: "Again", baseURL: base).close()
        #expect(prefs.closedClipboardDocuments.entries.isEmpty)
    }

    @Test("閉じた順に 10 件まで覚え、本文が上限を超えると古い文書から外す")
    func limitsHistory() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = AppPreferences(defaults: suite.defaults)
        let library = UserLibrary(root: root)
        var history = ClosedClipboardDocuments(byteLimit: 20)
        func remember(_ value: String) {
            let data = Data(value.utf8)
            let model = DocumentViewModel(
                data: data, fileURL: nil, format: .plainText, preferences: prefs,
                library: library, title: value)
            history.remember(.init(model: model, hash: .of(data), data: data, date: .now))
        }
        for i in 0..<12 { remember(String(i)) }
        #expect(history.entries.map(\.title) == (2..<12).reversed().map { String($0) })
        remember("012345678901234567")
        #expect(history.entries.map(\.title) == ["012345678901234567", "11"])
        remember(String(repeating: "x", count: 21))
        #expect(history.entries.count == 2)
    }

    @Test("ファイルメニューには URL と履歴の項目が一つずつあり、追跡を閉じた後で履歴の有無を反映する")
    func closedDocumentMenu() async throws {
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        defer {
            let visibleAfter = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            #expect(visibleAfter.isSubset(of: visibleBefore))
        }
        let windows = ClipboardWindows.shared
        let prefs = try #require(windows.preferences)
        let original = prefs.closedClipboardDocuments
        let wasKeeping = prefs.keepsClosedClipboardDocuments
        defer {
            prefs.keepsClosedClipboardDocuments = wasKeeping
            prefs.closedClipboardDocuments = original
        }
        let presentation = ClipboardWindowFixture(windows, ordered: true)
        defer { presentation.close() }
        prefs.keepsClosedClipboardDocuments = true
        prefs.closedClipboardDocuments = ClosedClipboardDocuments()
        let bridge = ShortcutDispatcher.shared.bridge
        let state = bridge.menuState
        func openRows() -> [DocumentMenuDescriptor] { DocumentMenuDescriptor.rows(for: .open, in: state.snapshot) }
        let history: DocumentMenuDescriptor.ID = .menu("Recently Closed Clipboard Documents")
        let reopen: DocumentMenuDescriptor.ID = .action(.operation(.clipboardReopen))
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(state.snapshot.content.history.isEmpty)
        #expect(!openRows().contains { $0.id == history || $0.id == reopen })

        let first = Data(UUID().uuidString.utf8)
        let second = Data(UUID().uuidString.utf8)
        let main = try #require(NSApp.mainMenu)
        // The inactive host materializes the launch menu with an empty, process-local clipboard history.
        let file = try #require(main.item(at: 1)?.submenu)
        #expect(file.item(withTitle: String(localized: "Recently Closed Clipboard Documents")) == nil)
        #expect(file.item(withTitle: String(localized: "Reopen Closed Clipboard Document")) == nil)
        let center = NotificationCenter.default
        do {
            defer { center.post(name: NSMenu.didEndTrackingNotification, object: main) }
            ShortcutMenuBaselineTests.trackingTurn {
                let writes = bridge.writes.counts
                let version = state.snapshot.version
                center.post(name: NSMenu.didBeginTrackingNotification, object: main)
                let hides = bridge.updates.hider.writes.counts
                windows.open(first, format: .plainText, title: "Menu sample").close()
                windows.open(second, format: .plainText, title: "Second sample").close()
                center.post(name: NSMenu.didChangeItemNotification, object: main)
                bridge.reconcile()
                #expect(state.snapshot.version == version)
                #expect(state.snapshot.content.history.isEmpty)
                #expect(!openRows().contains { $0.id == history || $0.id == reopen })
                #expect(bridge.writes.counts == writes)
                #expect(bridge.updates.hider.writes.counts == hides)
            }
        }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        let entries = state.snapshot.content.history
        #expect(entries.map(\.id) == [.of(second), .of(first)])
        let rows = openRows()
        for id: DocumentMenuDescriptor.ID in [.action(.operation(.appOpenURL)), reopen, history] {
            #expect(rows.filter { $0.id == id }.count == 1)
        }
        let children = try #require(rows.first { $0.id == history }).children
        #expect(children.map(\.id) == [.action(.history(.of(second))), .action(.history(.of(first)))])
        #expect(children.map(\.title) == entries.map { .verbatim($0.title) })
        try #require(entries.count == 2 && children.count == 2)
        #expect(entries[0].title.contains("Second sample"))
        #expect(entries[1].title.contains("Menu sample"))
        guard case .action(let older) = children[1].id, case .action(let newer) = children[0].id else {
            Issue.record("Expected two selectable history entries")
            return
        }
        older.perform(preferences: prefs)
        let reopened = try #require(
            NSApp.windows.compactMap { $0.windowController as? MemoryDocumentWindowController }
                .first { $0.model.memoryContent == first && $0.window?.isVisible == true })
        defer { reopened.close() }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(state.snapshot.content.history.map(\.id) == [.of(second)])
        let replacement = Data(UUID().uuidString.utf8)
        prefs.closedClipboardDocuments.remove(.of(second))
        windows.open(replacement, format: .plainText, title: "New occupant").close()
        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        newer.perform(preferences: prefs)
        #expect(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)) == visible)
        #expect(prefs.closedClipboardDocuments.entries.map(\.menuItem.id) == [.of(replacement)])
        prefs.keepsClosedClipboardDocuments = false
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(state.snapshot.content.history.isEmpty)
        #expect(!openRows().contains { $0.id == history || $0.id == reopen })
    }

    @Test("履歴の題名は一行で省略記号を含めて四十文字に収める")
    func cappedHistoryTitle() {
        let id = ContentHash.of(Data())
        let exactly = String(repeating: "紙", count: 40)
        #expect(ClosedClipboardDocuments.MenuItem(id: id, title: exactly).title == exactly)
        #expect(
            ClosedClipboardDocuments.MenuItem(id: id, title: exactly + "面").title == String(repeating: "紙", count: 39)
                + "…")
        #expect(ClosedClipboardDocuments.MenuItem(id: id, title: "一行目\n二行目").title == "一行目…")
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
