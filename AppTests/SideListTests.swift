import AppKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct SideListTests {
    @Test("一覧の幅を加えて右端を保ち紙の比率と最小幅を固定する")
    func windowSide() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 650),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        ViewerWindow.configure(window)
        let right = window.frame.maxX
        ViewerWindow.setPaperSize(
            CGSize(width: 300, height: 400), band: 38, of: window, animate: false,
            keepsRightEdge: true, side: 260)
        let content = window.contentRect(forFrameRect: window.frame)
        #expect(content.width == 560)
        #expect(content.height == 438)
        #expect(window.frame.maxX == right)
        ViewerWindow.lockAspectRatio(of: window, unit: CGSize(width: 3, height: 4), band: 38, side: 260)
        #expect(window.contentAspectRatio == CGSize(width: 560, height: 438))
        #expect(window.contentMinSize == CGSize(width: 470, height: 318))
    }

    @Test("画面幅から一覧を引いて紙を縦横とも縮める")
    func screenLimit() {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let size = ViewerWindow.paperSize(
            unit: CGSize(width: 2, height: 1), height: 10000, on: NSScreen.main, widthShare: 1, side: 260)
        #expect(size.width == (screenWidth - 260).rounded())
        #expect(size.height == ((screenWidth - 260) / 2).rounded())
    }

    @Test("奇数ページ開始は両面出力だけに効き保存値は選択を保つ")
    func oddPageSetting() throws {
        let fixture = Fixture()
        let model = fixture.model
        model.binderStartsOnFront = true
        model.layoutID = PrintLayout.a4Duplex.id
        #expect(try #require(model.renderSettings).binderStartsOnFront == false)
        model.enterPrintMode()
        #expect(try #require(model.renderSettings).binderStartsOnFront)
        model.layoutID = PrintLayout.a4Single.id
        #expect(try #require(model.renderSettings).binderStartsOnFront == false)
        #expect(model.rememberedSettings.binderStartsOnFront == true)
        model.stop()
    }

    @Test("行は刷り台への要求を出し見開きでは押した文書を選び続ける")
    func navigation() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error == nil)
        let binder = try #require(model.binder)
        let second = binder.urls[1]
        model.viewOptions = ViewOptions(
            layout: .spread, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        model.goToBinderDocument(second)
        model.paperDidChangePage(0)
        #expect(binder.selection == second)
        model.paperDidChangePage(2)
        #expect(binder.selection == binder.urls[2])
        model.enterPrintMode()
        try await render(model)
        model.goToBinderDocument(second)
        #expect(model.requestedTrayRow == 1)
    }

    @Test("組み直し中に押した行は、新しい用紙ができてからその文書の用紙へ移る")
    func trayRequestWaitsForSheets() async throws {
        let fixture = Fixture(pages: 2)
        let model = fixture.model
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        let binder = try #require(model.binder)
        let last = binder.urls[1]
        binder.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        model.render()
        model.goToBinderDocument(last)
        #expect(model.requestedTrayRow == nil)
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        // The list is c, a, b: b starts on the fifth sheet.
        #expect(model.requestedTrayRow == 4)
    }

    @Test("刷り台を離れたら行の要求は消え、次の刷り台で動かない")
    func trayRequestEndsWithTheTray() async throws {
        let fixture = Fixture(pages: 2)
        let model = fixture.model
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        let binder = try #require(model.binder)
        binder.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        model.render()
        model.goToBinderDocument(binder.urls[1])
        model.exitPrintMode()
        try await render(model)
        #expect(model.requestedTrayRow == nil)
        model.enterPrintMode()
        try await render(model)
        #expect(model.requestedTrayRow == nil)
    }

    @Test("刷り台のページが紙に残っている間の通知で読んでいる文書を変えない")
    func trayPagesDoNotMoveTheReader() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        try await render(model)
        model.paperDidChangePage(2)
        model.binderStartsOnFront = true
        model.layoutID = PrintLayout.a4Duplex.id
        model.enterPrintMode()
        try await render(model)
        #expect(model.binder?.pageStarts.values.sorted() == [0, 2, 4])
        model.mode = .view
        // The paper comes back with the tray's pages and reports the page it opens at.
        model.paperDidChangePage(2)
        try await render(model)
        #expect(model.currentPageIndex == 2)
    }

    @Test("ノートページが入っていても画像の順番から本文のページを求める")
    func bodyPages() {
        let plan = Imposition.plan(pageCount: 4, layout: .a4Duplex)
        let tray = PrintTray(plan: plan, layout: .a4Duplex, rotatesBackSides: false, notePages: [1, 3])
        #expect(tray.bodyPage(at: 0) == 1)
        #expect(tray.bodyPage(at: 1) == 3)
        #expect(tray.bodyPage(at: 2) == nil)
        #expect(tray.rowID(containing: 3) == 1)
    }

    @Test("一覧の開閉は右端と紙の高さを保ち刷り台と見比べ台には幅を足さない")
    func sideListGeometry() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        try await render(model)
        model.viewOptions = ViewOptions(
            layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let window = NSWindow(
            contentRect: NSRect(x: 500, y: 100, width: 400, height: 550),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        model.window = window
        model.sizeWindowToPaper()
        ViewerWindow.setPaperSize(
            CGSize(width: 283, height: 400),
            band: ViewerWindow.bandHeight * CGFloat(model.menuArrangement.bandCount), of: window, animate: false)
        let before = window.frame
        model.isDrawerOpen = true
        model.sizeWindowToPaper(keepsRightEdge: true)
        #expect(abs(window.frame.maxX - before.maxX) < 1)
        #expect(abs(window.frame.width - before.width - 260) < 1)
        #expect(window.frame.height == before.height)
        model.isDrawerOpen = false
        model.sizeWindowToPaper(keepsRightEdge: true)
        #expect(abs(window.frame.width - before.width) < 1)
        model.isDrawerOpen = true
        model.enterPrintMode()
        #expect(model.sideInset == 0)
    }

    @Test("一覧を開いたまま窓を変えても紙だけの大きさで整える")
    func resizeWithList() async throws {
        let fixture = Fixture()
        let model = fixture.model
        defer { model.stop() }
        try await render(model)
        model.viewOptions = ViewOptions(
            layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 100, width: 700, height: 500),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        model.window = window
        model.isDrawerOpen = true
        model.sizeWindowToPaper()
        window.setContentSize(NSSize(width: 660, height: 500))
        model.windowDidEndLiveResize()
        let paper = try #require(model.currentPaperSize)
        #expect(paper.width == 400)
        #expect(abs(paper.height - 400 * 842 / 595) < 1)
    }

    @Test("見比べ台には一覧の幅を足さない")
    func comparisonHasNoSideInset() {
        let fixture = Fixture()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: fixture.model.preferences, library: fixture.model.library,
            binder: BinderModel(urls: [URL(fileURLWithPath: "/fixture/a.md")]))
        defer { model.stop() }
        model.isDrawerOpen = true
        #expect(model.sideInset == 260)
        model.enterCompareMode()
        #expect(model.mode == .compare)
        #expect(model.sideInset == 0)
    }

    @Test("組み直しの結果を渡す前に同じ文書の同じページへ換算する")
    func renderKeepsReadingSpot() async throws {
        let fixture = Fixture(pages: 3)
        let model = fixture.model
        defer { model.stop() }
        try await render(model)
        let binder = try #require(model.binder)
        model.paperDidChangePage(4)
        binder.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try await render(model)
        #expect(model.currentPageIndex == 1)
        let removed = binder.urls[0]
        binder.remove(removed)
        try await render(model)
        #expect(model.currentPageIndex == 0)
    }

    private func render(_ model: DocumentViewModel) async throws {
        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isRendering)
        #expect(model.error == nil)
        _ = try #require(model.result)
    }

    @MainActor
    private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model: DocumentViewModel

        init(pages: Int = 1) {
            let data = TestFixtures.pdf("side-list", pages: pages)
            let binder = BinderModel(
                urls: ["a", "b", "c"].map { URL(fileURLWithPath: "/fixture/\($0).pdf") }, read: { _ in data })
            model = DocumentViewModel(
                data: Data(), fileURL: nil, format: .pdf,
                preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root), binder: binder)
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
