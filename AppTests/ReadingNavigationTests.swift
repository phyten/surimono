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

        func bundleModel() -> DocumentViewModel {
            let urls = ["a.png", "b.png", "c.png"].map { directory.appendingPathComponent($0) }
            let images = Dictionary(uniqueKeysWithValues: zip(urls, [0.1, 0.3, 0.5].map { TestFixtures.png(red: $0) }))
            let bundle = ImageBundleModel(urls: urls) { url in
                guard let bytes = images[url] else { throw CocoaError(.fileNoSuchFile) }
                return bytes
            }
            return DocumentViewModel(
                data: Data(), fileURL: nil, format: .image, preferences: preferences, library: library,
                imageBundle: bundle, settingsStore: store)
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

    @Test("見開きの後半へ飛ぶと一枚ずつ進めて、履歴も後半のページへ戻る")
    func scrubSpread() async throws {
        let fixture = Fixture()
        fixture.preferences.menuArrangement = .split
        let model = fixture.model()
        defer { model.stop() }
        try await start(model)
        model.updateViewOptions {
            $0.layout = .spread
            $0.showsCoverAlone = false
        }
        model.scrubToPage(11)
        #expect(model.currentPageIndex == 10 && model.logicalReadingPage == 11)
        #expect(model.visibleReadingPages == [10, 11])
        #expect(!model.handleScrubKey(.rightArrow))
        model.scrubber.keyboardFocus = true
        #expect(model.handleScrubKey(.rightArrow))
        #expect(model.logicalReadingPage == 12)
        model.goBack()
        #expect(model.currentPageIndex == 10 && model.logicalReadingPage == 11)
        model.goBack()
        #expect(model.logicalReadingPage == 0 && !model.pageHistory.canGoBack)
        model.goForward()
        #expect(model.logicalReadingPage == 11)
    }

    @Test("スクラバーは下の帯の上下端で入力を受け、左右の余白にはみ出さない", .timeLimit(.minutes(1)))
    func scrubHitArea() async throws {
        let fixture = Fixture()
        fixture.preferences.menuArrangement = .split
        let model = fixture.model()
        let controller = MemoryDocumentWindowController(model: model) {}
        defer { controller.close() }
        let window = try #require(controller.window)
        window.orderFront(nil)
        for _ in 0..<500 where !model.isUpToDate { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.pageCount == 60)
        model.isBandAlwaysVisible = true
        window.setContentSize(CGSize(width: 1180, height: 620))
        let content = try #require(window.contentView)
        var previous = CGRect.zero
        for _ in 0..<250 {
            try await Task.sleep(for: .milliseconds(20))
            content.layoutSubtreeIfNeeded()
            let frame = model.scrubber.frame
            if frame.width >= BandLayout.scrubberMinimum, frame == previous { break }
            previous = frame
        }
        let frame = model.scrubber.frame
        try #require(frame.width >= BandLayout.scrubberMinimum)
        #expect(frame.height == ViewerWindow.bandHeight)
        func hitsTrack(x: CGFloat, y: CGFloat) -> Bool {
            let point = CGPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y)
            return content.hitTest(content.convert(point, to: content.superview)) is ScrubPointer.Input
        }
        #expect(hitsTrack(x: frame.midX, y: frame.minY + 1))
        #expect(hitsTrack(x: frame.midX, y: frame.maxY - 1))
        #expect(!hitsTrack(x: frame.minX - 2, y: frame.midY))
        #expect(!hitsTrack(x: frame.maxX + 2, y: frame.midY))
    }

    @Test("ドラッグ中に帯を離れても追跡し、取り消した後の解放は移動しない")
    func scrubCancellation() {
        let state = PageScrubSession()
        state.press(0.2)
        state.leave()
        #expect(state.dragging && state.holdsBand && state.showsPreview)
        state.point(1.5, immediately: true)
        #expect(state.fraction == 1)
        state.cancel()
        #expect(state.release(0.9, inside: true) == nil)
        #expect(!state.holdsBand && !state.showsPreview)
        state.press(0.5)
        #expect(state.release(-1, inside: false) == 0)
        #expect(!state.holdsBand)
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

    private func render(_ model: DocumentViewModel, starting action: () -> Void) async throws {
        let succeeded = await withCheckedContinuation { continuation in
            model.onFirstRender = { continuation.resume(returning: $0) }
            action()
        }
        try #require(succeeded)
    }

    @Test("画像一覧の未確定の選択は再読み込みや並べ替えで紙を動かさず、確定した移動だけを戻せる")
    func bundleReadingPosition() async throws {
        let fixture = Fixture()
        let model = fixture.bundleModel()
        defer { model.stop() }
        try await render(model, starting: model.start)
        model.setLayout(.single)
        let bundle = try #require(model.imageBundle)
        let urls = bundle.urls
        model.paperDidChangePage(1)
        // Arrow keys select the target for list commands before Return commits a reading jump.
        bundle.selection = urls[2]
        try await render(model, starting: model.reload)
        #expect(model.currentPageIndex == 1)
        model.paperDidChangePage(1)
        #expect(bundle.selection == urls[2])
        #expect(!model.pageHistory.canGoBack)
        bundle.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        try await render(model, starting: model.listDidChange)
        #expect(model.currentPageIndex == 0)
        #expect(!model.pageHistory.canGoBack)
        model.paperDidChangePage(0)
        let selected = try #require(bundle.selection)
        #expect(selected == urls[2])
        model.goToBundleImage(selected)
        #expect(model.currentPageIndex == 1)
        model.goBack()
        #expect(model.currentPageIndex == 0 && !model.pageHistory.canGoBack)
    }

    @Test("並べ替えで表示画像が見開きの後半に移っても、紙面の通知は一覧の未確定の選択を保つ")
    func bundleSelectionAfterSpreadReorder() async throws {
        let fixture = Fixture()
        let model = fixture.bundleModel()
        defer { model.stop() }
        try await render(model, starting: model.start)
        model.updateViewOptions {
            $0.layout = .spread
            $0.showsCoverAlone = false
        }
        let bundle = try #require(model.imageBundle)
        let urls = bundle.urls
        try #require(model.visibleReadingPages == [0, 1])
        bundle.selection = urls[2]
        bundle.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try await render(model, starting: model.listDidChange)
        try #require(model.currentPageIndex == 1)
        // The replacement PDF reports the first page of the spread containing the restored image.
        model.paperDidChangePage(0)
        #expect(bundle.selection == urls[2])
        #expect(model.currentPageIndex == 0)
        bundle.selection = urls[0]
        model.paperDidChangePage(2)
        #expect(bundle.selection == urls[2])
    }

    @Test("ドラッグで開いた画像一覧は終了時に元へ戻り、文書の設定記録を作らない", arguments: [false, true])
    func temporaryDrawer(alreadyOpen: Bool) async throws {
        let fixture = Fixture()
        let model = fixture.bundleModel()
        defer { model.stop() }
        try await render(model, starting: model.start)
        let key = try #require(model.contentHash?.hex)
        if alreadyOpen {
            model.toggleBookmark()
            model.selectContentsTab(.contents)
            model.setContentsOpen(true)
        }
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        let saved = fixture.store.token(for: key)
        try #require((saved != nil) == alreadyOpen)
        let previous = model.rememberedSettings
        let tab = model.contentsTab
        model.drop.listButtonFrame = CGRect(x: 0, y: 0, width: 40, height: 20)
        let target = fixture.directory.appendingPathComponent("new.png")
        try #require(model.dragEntered([target], at: CGPoint(x: 5, y: 5)))
        let spring = try #require(model.drop.springTask)
        await spring.value
        try #require(model.isDrawerOpen && model.contentsTab == .pages)
        #expect(model.rememberedSettings == previous)
        // Flush the same change notification as DocumentViewer, even if the reader lingers before cancelling.
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.token(for: key) == saved)
        model.drop.end()
        #expect(model.isDrawerOpen == alreadyOpen && model.contentsTab == tab)
        model.rememberedSettingsDidChange()
        model.flushPendingSettings()
        #expect(fixture.store.token(for: key) == saved)
    }

    @Test("組み直しで縮図を描き直し、遅れて届いた旧世代の画像を表示しない", .timeLimit(.minutes(1)))
    func thumbnailGeneration() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        defer { model.stop() }
        try await render(model, starting: model.start)
        let old = try #require(model.result?.id)
        let cache = try #require(model.thumbnails(for: old))
        let oldImage = try #require(await cache.image(page: 0, pixels: 64))
        try await render(model) {
            model.render()
            #expect(model.thumbnails(for: old) == nil)
        }
        let generation = try #require(model.result?.id)
        #expect(generation != old)
        #expect(model.thumbnails(for: old) == nil)
        let fresh = try #require(model.thumbnails(for: generation))
        #expect(fresh !== cache)
        let newImage = try #require(await fresh.image(page: 0, pixels: 64))

        var tile = PageTileThumbnail()
        let previous = PageTileThumbnail.Request(generation: old, page: 0, pixels: 64)
        let current = PageTileThumbnail.Request(generation: generation, page: 0, pixels: 64)
        tile.begin(previous)
        tile.receive(oldImage, for: previous)
        #expect(tile.image(for: current) == nil)
        tile.begin(current)
        tile.receive(newImage, for: current)
        // Deliver the held response after the new bitmap is on screen.
        tile.receive(oldImage, for: previous)
        #expect(tile.image(for: current) === newImage)
        #expect(tile.image(for: previous) == nil)
        #expect(tile.image(for: nil) == nil)
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
