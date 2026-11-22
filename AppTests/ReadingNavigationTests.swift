import Foundation
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct ReadingNavigationTests {
    @MainActor
    private final class Fixture {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = TestFixtures.pdf("Reading", pages: 60)
        let store: DocumentSettingsStore
        let preferences: AppPreferences
        let library: UserLibrary

        init() {
            store = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: directory.appendingPathComponent("Library"))
        }

        func model() -> DocumentViewModel {
            let model = DocumentViewModel(
                data: data, fileURL: nil, format: .pdf, preferences: preferences, library: library, settingsStore: store
            )
            model.printSubmit = { _, _, _ in Issue.record("Printing is forbidden") }
            model.outputOverride = { _, _ in Issue.record("Output is forbidden") }
            return model
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func start(_ model: DocumentViewModel) async throws {
        model.start()
        for _ in 0..<500 where model.contentHash == nil || model.result == nil || model.isRendering {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.pageCount == 60)
        model.setLayout(.single)
    }

    @Test("表示中のページにしおりを付けるとメニューを開かずにチェックを公開する", .timeLimit(.minutes(1)))
    func publishesBookmark() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        let state = MenuState()
        let updates = MenuUpdates(
            state: state, root: { nil }, model: { model }, preferences: { fixture.preferences },
            lifecycle: NotificationCenter(), apply: { _ in })
        updates.start()
        defer { updates.stop() }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        let before = state.snapshot
        #expect(!before.content.bookmarked)
        model.toggleBookmark()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(state.snapshot.version == before.version + 1 && state.snapshot.content.bookmarked)
    }

    @Test("目次で飛んで読み進め、戻ると飛ぶ前、進むと読んだ場所へ移る", .timeLimit(.minutes(1)))
    func outlineHistory() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.currentPageIndex = 10
        model.goToOutlineEntry(OutlineEntry(level: 1, title: "Chapter", pageIndex: 50))
        #expect(model.currentPageIndex == 50)
        model.currentPageIndex = 53
        model.goBack()
        #expect(model.currentPageIndex == 10)
        model.goForward()
        #expect(model.currentPageIndex == 53)
        model.goToOutlineEntry(OutlineEntry(level: 1, title: "Same", pageIndex: 53))
        model.goBack()
        #expect(model.currentPageIndex == 10)
    }

    @Test("普通のページ通知と検索では履歴を積まず紙のないモードでは操作しない", .timeLimit(.minutes(1)))
    func ordinaryTurns() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.paperDidChangePage(3)
        model.paperDidChangePage(4)
        model.findStep(forward: true)
        #expect(!model.pageHistory.canGoBack)
        model.goToPage(entered: "20")
        #expect(model.currentPageIndex == 19)
        model.mode = .print
        model.goBack()
        model.toggleBookmark()
        model.goToPage(entered: "40")
        #expect(model.currentPageIndex == 19 && model.bookmarks.isEmpty)
        model.mode = .compare
        model.goBack()
        #expect(model.currentPageIndex == 19)
        model.mode = .view
        model.goBack()
        #expect(model.currentPageIndex == 4)
    }

    @Test("しおりを保存して復元し、しおりだけの記録でも復元の知らせを出さない", .timeLimit(.minutes(1)))
    func persistence() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.currentPageIndex = 10
        model.toggleBookmark()
        model.flushPendingSettings()
        let key = try #require(model.contentHash?.hex)
        #expect(fixture.store.record(for: key)?.bookmarks == model.bookmarks)
        try fixture.store.save(DocumentSettings(bookmarks: model.bookmarks), for: key)
        let restored = fixture.model()
        defer { restored.stop() }
        try await start(restored)
        #expect(restored.bookmarkPages == [10])
        #expect(restored.toast == nil)
        #expect(!restored.pageHistory.canGoBack)
    }

    @Test("すべて戻してもしおりをメモリと保存記録に残す", .timeLimit(.minutes(1)))
    func resetKeepsMarks() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.currentPageIndex = 8
        model.toggleBookmark()
        model.zoom = 2
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        model.resetDocumentSettings()
        #expect(model.zoom == 1)
        #expect(model.bookmarkPages == [8])
        let key = try #require(model.contentHash?.hex)
        #expect(fixture.store.record(for: key)?.bookmarks == model.bookmarks)
        #expect(fixture.store.record(for: key)?.zoom == nil)
        model.undoResetDocumentSettings()
        #expect(model.bookmarkPages == [8])
        #expect(model.zoom == 2)
    }

    @Test("見出しがなくてもしおりから目次を開け、次と前は見開きの外へ移る", .timeLimit(.minutes(1)))
    func contentsAndSpreads() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        #expect(!model.hasOutline && model.hasContents)
        #expect(model.contentsTab == .pages)
        for page in [0, 4, 5, 10] { model.toggleBookmark(page: page, visiblePages: [page]) }
        #expect(model.hasContents && !model.hasOutline)
        model.toggleOutline()
        #expect(model.isOutlineShown)
        model.viewOptions.showsCoverAlone = false
        model.setLayout(.spread)
        model.currentPageIndex = 4
        #expect(model.isVisiblePageBookmarked)
        model.goToNextBookmark()
        #expect(model.currentPageIndex == 10)
        model.goBack()
        #expect(model.currentPageIndex == 4)
        model.goToPreviousBookmark()
        #expect(model.currentPageIndex == 0)
        model.currentPageIndex = 4
        model.toggleBookmark()
        #expect(model.bookmarkPages == [0, 10])
    }

    @Test("引き出しの開閉・幅・タブだけを変えても文書ごとに復元できる", .timeLimit(.minutes(1)))
    func remembersPanel() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        #expect(model.rememberedSettings.contentsPanel == nil)
        model.selectContentsTab(.pages)
        model.setContentsOpen(true)
        model.contentsPanel.width = 312
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        let restored = fixture.model()
        defer { restored.stop() }
        try await start(restored)
        #expect(restored.contentsTab == .pages)
        #expect(restored.contentsWidth == 312)
        #expect(restored.isOutlineDrawerOpen)
        restored.setContentsOpen(false)
        #expect(restored.rememberedSettings.contentsPanel?.isOpen == false)
    }

    @Test("組み直しが始まれば古い世代は使えず、新しい紙には別のキャッシュを使う", .timeLimit(.minutes(1)))
    func thumbnailGeneration() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        let old = try #require(model.result?.id)
        let cache = try #require(model.thumbnails(for: old))
        model.render()
        #expect(model.thumbnails(for: old) == nil)
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        let generation = try #require(model.result?.id)
        #expect(generation != old)
        #expect(model.thumbnails(for: old) == nil)
        #expect(model.thumbnails(for: generation) !== cache)
    }

    @Test("同じページに始まる章は最後の見出しを使い、最初の章より前も一度ずつ並べる")
    func chapterSections() {
        let sections = PageSection.sections(
            count: 5,
            chapters: [
                OutlineEntry(level: 2, title: "One", pageIndex: 1),
                OutlineEntry(level: 2, title: "Two", pageIndex: 1),
                OutlineEntry(level: 2, title: "Three", pageIndex: 4),
            ])
        #expect(sections.map(\.pages) == [0..<1, 1..<4, 4..<5])
        #expect(sections.map(\.title) == [nil, "Two", "Three"])
        #expect(PageSection.verticalNeighbor(of: 0, down: true, columns: 2, sections: sections) == 1)
        #expect(PageSection.verticalNeighbor(of: 4, down: false, columns: 2, sections: sections) == 3)
    }

    @Test("追加した既定キーは他の既定と固定キーに重ならない")
    func defaultsDoNotConflict() {
        let validator = ShortcutValidator(environment: .init())
        #expect(validator.conflicts(in: ShortcutConfiguration()).isEmpty)
        for id: ShortcutOperationID in [
            .readingBack, .readingForward, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious,
        ] {
            let operation = ShortcutOperation.operation(id)
            #expect(operation.applicability == .paperWithPages)
            #expect(operation.regions == [.paperReading, .paperSelection])
            for key in operation.defaults {
                #expect(ShortcutValidator.staticRefusal(key) == nil)
            }
        }
    }
}
