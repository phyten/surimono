import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ViewBandTests {
    @MainActor private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: TestDefaultsSuite

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = TestDefaultsSuite()
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: directory.appendingPathComponent("Library"))
            store = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }

        func model(_ data: Data, format: DocumentFormat = .pdf, pages: Data? = nil) -> DocumentViewModel {
            let renderer = DocumentRenderer(paginate: { _ in
                try #require(PDFDocument(data: pages ?? TestFixtures.pdf("Pages")))
            })
            return DocumentViewModel(
                data: data, fileURL: nil, format: format, preferences: preferences, library: library,
                renderer: renderer, settingsStore: store)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func wideDocument(page: CGSize) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<4 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func paperSize(of window: NSWindow, _ model: DocumentViewModel) -> CGSize {
        let content = window.contentRect(forFrameRect: window.frame).size
        let band = ViewerWindow.bandHeight * CGFloat(model.menuArrangement.bandCount)
        return CGSize(width: content.width, height: content.height - band)
    }

    private func open(_ model: DocumentViewModel) async throws {
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
    }

    @Test("新しい設定の既定は上と下に分ける・常に表示・ポップオーバー・ツールバーに目次・トースト")
    func defaults() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        #expect(preferences.menuArrangement == .split)
        #expect(preferences.defaultBandVisibility == .always)
        #expect(preferences.outlinePresentation == .popover)
        #expect(preferences.showsOutlineOnBand)
        #expect(preferences.changeFollowing == .ask)
    }

    @Test("設定は次の起動でも覚えている")
    func preferencesPersist() {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .top
        environment.preferences.outlinePresentation = .drawer
        environment.preferences.showsOutlineOnBand = false
        environment.preferences.changeFollowing = .jump
        let restored = AppPreferences(defaults: environment.suite.defaults)
        #expect(restored.menuArrangement == .top)
        #expect(restored.outlinePresentation == .drawer)
        #expect(!restored.showsOutlineOnBand)
        #expect(restored.changeFollowing == .jump)
    }

    @Test("旧版の常に固定の記録は常に出すとして読む")
    func migratesPinnedDefault() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "defaultMenuPinned")
        #expect(AppPreferences(defaults: suite.defaults).defaultBandVisibility == .always)
    }

    @Test("旧版で固定しないと決めていた記録は、乗せたときだけのまま読む")
    func keepsUnpinnedRecord() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(false, forKey: "defaultMenuPinned")
        #expect(AppPreferences(defaults: suite.defaults).defaultBandVisibility == .onHover)
    }

    @Test("新しい設定を選んだあとは旧版の記録より優先する")
    func newChoiceWinsOverPinnedRecord() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "defaultMenuPinned")
        AppPreferences(defaults: suite.defaults).defaultBandVisibility = .onHover
        #expect(AppPreferences(defaults: suite.defaults).defaultBandVisibility == .onHover)
    }

    /// The paper view's height in the window, which shows whether any room is left beside the paper.
    private func paperViewHeight(in window: NSWindow) -> CGFloat? {
        func find(_ view: NSView) -> NSView? {
            if view is PaperPDFView { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let content = window.contentView, let paper = find(content) else { return nil }
        return paper.convert(paper.bounds, to: nil).height
    }

    @Test(
        "ツールバーを常に表示から外すと窓は紙だけの大きさに戻り、紙は画面の上で動かない",
        arguments: MenuArrangement.allCases)
    func turningToolbarOffLeavesOnlyPaper(arrangement: MenuArrangement) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = arrangement
        environment.preferences.defaultBandVisibility = .always
        let model = environment.model(TestFixtures.pdf("Toolbar"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        // Room around the window, or it would be moved to stay on the screen.
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 80))
        let room: CGFloat = arrangement == .split ? 76 : 38
        let pinned = window.contentRect(forFrameRect: window.frame)
        let paper = CGSize(width: pinned.width, height: pinned.height - room)
        let paperTop = pinned.maxY - 38

        model.isBandAlwaysVisible = false
        let off = window.contentRect(forFrameRect: window.frame)
        #expect(abs(off.width - paper.width) <= 3)
        #expect(abs(off.height - paper.height) <= 3)
        #expect(abs(off.maxY - paperTop) <= 3)
        try await waitUntil { abs((paperViewHeight(in: window) ?? 0) - off.height) <= 3 }

        model.isBandAlwaysVisible = true
        let on = window.contentRect(forFrameRect: window.frame)
        #expect(abs(on.height - paper.height - room) <= 3)
        #expect(abs(on.maxY - 38 - paperTop) <= 3)
        try await waitUntil { abs((paperViewHeight(in: window) ?? 0) - paper.height) <= 3 }
    }

    @Test("常に表示のまま利用者が窓を広げたあとでも、外すと窓は紙だけの大きさになる", arguments: MenuArrangement.allCases)
    func turningToolbarOffAfterResize(arrangement: MenuArrangement) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = arrangement
        environment.preferences.defaultBandVisibility = .always
        let model = environment.model(TestFixtures.pdf("Resized"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 80))
        // As the reader drags the window's corner narrower; the app then settles on the paper's exact height.
        var frame = window.frame
        frame.size.width -= 60
        window.setFrame(frame, display: true)
        model.windowDidEndLiveResize()
        let room: CGFloat = arrangement == .split ? 76 : 38
        let pinned = window.contentRect(forFrameRect: window.frame)
        let unit = try #require(model.paperUnitSize)
        #expect(abs((pinned.height - room) / pinned.width - unit.height / unit.width) < 0.01)

        model.isBandAlwaysVisible = false
        let off = window.contentRect(forFrameRect: window.frame)
        #expect(abs(off.height / off.width - unit.height / unit.width) < 0.01)
        #expect(abs(off.height - (pinned.height - room)) <= 3)
        try await waitUntil { abs((paperViewHeight(in: window) ?? 0) - off.height) <= 3 }
    }

    @Test("上だけなら帯 1 本ぶん、上と下に分けると 2 本ぶんの場所を紙の外に取る")
    func bandRoomFollowsArrangement() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .top
        let model = environment.model(TestFixtures.pdf("Room"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        let unit = try #require(model.paperUnitSize)
        let paper = ViewerWindow.initialPaperSize(unit: unit, on: window.screen)
        #expect(abs(window.contentRect(forFrameRect: window.frame).height - paper.height - 38) <= 1)
        // Room below the window, or it would be moved to stay on the screen.
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
        let top = window.frame.maxY
        environment.preferences.menuArrangement = .split
        try await waitUntil { abs(window.contentRect(forFrameRect: window.frame).height - paper.height - 76) <= 1 }
        #expect(abs(window.frame.maxY - top) <= 1)
    }

    @Test("見開きの幅が画面に入らないときは高さも縮めて形を保ち、単ページへ戻すと元の高さになる")
    func tooWideSpreadKeepsItsShape() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let visible = try #require(NSScreen.main?.visibleFrame)
        let page = CGSize(width: (visible.width * 0.7).rounded(), height: (visible.width * 0.4).rounded())
        let model = environment.model(try wideDocument(page: page))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.updateViewOptions { $0.showsCoverAlone = false }
        model.sizeWindowToPaper(initialOnly: true)
        let height = paperSize(of: window, model).height

        model.setLayout(.spread)
        model.sizeWindowToPaper()
        let spread = paperSize(of: window, model)
        #expect(spread.width <= visible.width + 1)
        #expect(abs(spread.width / spread.height - page.width * 2 / page.height) < 0.02)

        model.setLayout(.single)
        model.sizeWindowToPaper()
        #expect(abs(paperSize(of: window, model).height - height) <= 1)
    }

    @Test("見開きで利用者が窓の大きさを変えたら、単ページへ戻しても前の高さに戻さない")
    func resizingForgetsTheOlderHeight() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let visible = try #require(NSScreen.main?.visibleFrame)
        let page = CGSize(width: (visible.width * 0.7).rounded(), height: (visible.width * 0.4).rounded())
        let model = environment.model(try wideDocument(page: page))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        defer { controller.close() }
        try await open(model)
        model.updateViewOptions { $0.showsCoverAlone = false }
        model.sizeWindowToPaper(initialOnly: true)
        model.setLayout(.spread)
        model.sizeWindowToPaper()
        try await Task.sleep(for: .milliseconds(50))
        model.windowDidEndLiveResize()
        let height = paperSize(of: window, model).height

        model.setLayout(.single)
        model.sizeWindowToPaper()
        #expect(abs(paperSize(of: window, model).height - height) <= 1)
    }

    @Test("帯の出し方は文書ごとに覚え、既定と同じなら記録を増やさない")
    func visibilityIsRememberedPerDocument() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let data = TestFixtures.pdf("Remember")
        let first = environment.model(data)
        try await open(first)
        #expect(first.rememberedSettings.bandVisibility == nil)
        first.bandVisibility = .onHover
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        let second = environment.model(data)
        defer { second.stop() }
        try await open(second)
        #expect(second.bandVisibility == .onHover)
        second.resetDocumentSettings()
        #expect(second.bandVisibility == .always)
    }

    @Test("文字の文書は A判 / B判 を切り替えられ、B判は B5 の用紙で組み、記録に残す")
    func paperSeriesChangesLayout() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let data = Data("# 見出し\n\n本文".utf8)
        let first = environment.model(data, format: .markdown)
        try await open(first)
        #expect(first.offersPaperSeries)
        #expect(first.renderSettings?.layout == .a4Single)
        #expect(first.rememberedSettings.paperSeries == nil)
        first.paperSeries = .b
        #expect(first.renderSettings?.layout == .b5Single)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        let second = environment.model(data, format: .markdown)
        defer { second.stop() }
        try await open(second)
        #expect(second.paperSeries == .b)
        #expect(second.renderSettings?.layout == .b5Single)
    }

    @Test("刷り台は紙の判ではなく印刷レイアウトで組む")
    func trayKeepsPrintLayout() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文".utf8), format: .markdown)
        defer { model.stop() }
        model.paperSeries = .b
        model.layoutID = PrintLayout.a4Duplex.id
        model.mode = .print
        #expect(model.renderSettings?.layout == .a4Duplex)
    }

    @Test("PDF と画像には紙の判の切り替えを出さない")
    func paperSeriesNeedsText() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let pdf = environment.model(TestFixtures.pdf("PDF"))
        let image = environment.model(TestFixtures.png(red: 1), format: .image)
        defer {
            pdf.stop()
            image.stop()
        }
        #expect(!pdf.offersPaperSeries)
        #expect(!image.offersPaperSeries)
        #expect(!SecondaryViewControl.applicable(for: pdf).contains(.paperSeries))
    }

    @Test("Markdown の見出しは [TOC] がなくても目次になり、そのページを持つ")
    func markdownOutline() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(
            Data("# First Chapter\n\nbody\n\n# Second Chapter\n\nbody".utf8), format: .markdown,
            pages: TestFixtures.textPDF(["First Chapter", "Body", "Second Chapter"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { !model.outlineEntries.isEmpty }
        #expect(
            model.outlineEntries == [
                OutlineEntry(level: 1, title: "First Chapter", pageIndex: 0),
                OutlineEntry(level: 1, title: "Second Chapter", pageIndex: 2),
            ])
        #expect(model.hasOutline)
        #expect(BandLayout.Item.applicable(for: model).contains(.outline))
    }

    @Test("今のページに応じて読んでいる章を選ぶ")
    func currentChapter() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(
            Data("# First Chapter\n\n# Second Chapter".utf8), format: .markdown,
            pages: TestFixtures.textPDF(["First Chapter", "Body", "Second Chapter", "Body"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { !model.outlineEntries.isEmpty }
        model.setLayout(.single)
        model.currentPageIndex = 1
        #expect(model.currentOutlineEntry == 0)
        model.currentPageIndex = 3
        #expect(model.currentOutlineEntry == 1)
    }

    @Test("見出しのない文書には目次を出さない")
    func noHeadingsNoOutline() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文だけ".utf8), format: .markdown)
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.documentStatistics != nil }
        #expect(!model.hasOutline)
        #expect(!BandLayout.Item.applicable(for: model).contains(.outline))
    }

    @Test("帯から外す設定では目次の部品を帯に置かない")
    func outlineCanLeaveTheBand() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.showsOutlineOnBand = false
        let model = environment.model(
            Data("# First Chapter".utf8), format: .markdown, pages: TestFixtures.textPDF(["First Chapter"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.hasOutline }
        #expect(!BandLayout.Item.applicable(for: model).contains(.outline))
    }

    @Test("目次の出し方に従ってポップオーバーか引き出しを開く")
    func outlinePresentation() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(
            Data("# First Chapter".utf8), format: .markdown, pages: TestFixtures.textPDF(["First Chapter"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.hasOutline }
        model.toggleOutline()
        #expect(model.isOutlinePresented)
        #expect(!model.showsOutlineDrawer)
        model.toggleOutline()
        environment.preferences.outlinePresentation = .drawer
        model.toggleOutline()
        #expect(!model.isOutlinePresented)
        #expect(model.showsOutlineDrawer)
    }

    @Test("ポップオーバーの目次は項目を選ぶと閉じる")
    func choosingEntryClosesPopover() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(TestFixtures.pdf("Choose"))
        defer { model.stop() }
        model.isOutlinePresented = true
        model.goToOutlineEntry(OutlineEntry(level: 1, title: "章", pageIndex: 1))
        #expect(!model.isOutlinePresented)
    }

    @Test("文字の文書は文字数を持ち、PDF は持たない")
    func statisticsNeedText() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let text = environment.model(Data("# 見出し\n\n本文です".utf8), format: .markdown)
        let pdf = environment.model(TestFixtures.pdf("Figures"))
        defer {
            text.stop()
            pdf.stop()
        }
        try await open(text)
        try await open(pdf)
        try await waitUntil { text.documentStatistics != nil }
        #expect(text.documentStatistics?.characters == 7)
        #expect(pdf.documentStatistics == nil)
    }

    @Test("文書の数字から刷り台へ移ると数字を閉じる")
    func figuresLeadToTray() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(TestFixtures.pdf("Tray"))
        defer { model.stop() }
        model.isFiguresPresented = true
        model.checkFiguresOnTray()
        #expect(!model.isFiguresPresented)
        #expect(model.mode == .print)
    }

    @Test("ページ送りのボタンは 2 ページ以上ある上下分割の下の帯にだけ置く")
    func pageTurnNeedsPagesAndSplit() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(TestFixtures.pdf("Turn"))
        defer { model.stop() }
        #expect(!BandLayout.Item.applicable(for: model).contains(.pageTurn))
        try await open(model)
        #expect(BandLayout.Item.applicable(for: model).contains(.pageTurn))
        environment.preferences.menuArrangement = .top
        #expect(!BandLayout.Item.applicable(for: model).contains(.pageTurn))
    }
}
