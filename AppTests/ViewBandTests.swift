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
    /// The top band follows the traffic lights (32pt on macOS 26); the bottom band keeps its own height.
    private static let top = ViewerWindow.titleBandHeight
    private static let bottom = ViewerWindow.bandHeight
    @MainActor private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: BandTestDefaultsSuite

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = BandTestDefaultsSuite()
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
            let model = DocumentViewModel(
                data: data, fileURL: nil, format: format, preferences: preferences, library: library,
                renderer: renderer, settingsStore: store)
            model.isolateBandTestOutput()
            return model
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
        let band = BandRoom.full(for: model.menuArrangement).total
        return CGSize(width: content.width, height: content.height - band)
    }

    private func open(_ model: DocumentViewModel) async throws {
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
    }

    @Test("新しい設定の既定は上と下に分ける・常に表示・ポップオーバー・ツールバーに目次・変更へ移動")
    func defaults() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        #expect(preferences.menuArrangement == .split)
        #expect(preferences.defaultBandVisibility == .always)
        #expect(preferences.outlinePresentation == .popover)
        #expect(preferences.showsOutlineOnBand)
        #expect(preferences.changeFollowing == .jump)
    }

    @Test("設定は次の起動でも覚えている")
    func preferencesPersist() {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .top
        environment.preferences.outlinePresentation = .drawer
        environment.preferences.showsOutlineOnBand = false
        environment.preferences.changeFollowing = .ask
        let restored = AppPreferences(defaults: environment.suite.defaults)
        #expect(restored.menuArrangement == .top)
        #expect(restored.outlinePresentation == .drawer)
        #expect(!restored.showsOutlineOnBand)
        #expect(restored.changeFollowing == .ask)
    }

    @Test("変更の色と自動読み直しを保存し不正な色は既定に戻す")
    func savedChangeColors() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let preferences = environment.preferences
        let defaults = environment.suite.defaults
        #expect(preferences.reloadsChangedFiles)
        #expect(preferences.changeBackgroundHex == "#FFF2A8")
        #expect(preferences.changeTextHex == nil)
        preferences.reloadsChangedFiles = false
        preferences.changeBackgroundHex = "#123456"
        preferences.changeTextHex = "#ABCDEF"
        let saved = AppPreferences(defaults: defaults)
        #expect(!saved.reloadsChangedFiles)
        #expect(saved.changeBackgroundHex == "#123456")
        #expect(saved.changeTextHex == "#ABCDEF")
        saved.changeTextHex = nil
        #expect(defaults.object(forKey: "changeTextHex") == nil)
        defaults.set("#-12345", forKey: "changeBackgroundHex")
        defaults.set("not a color", forKey: "changeTextHex")
        let repaired = AppPreferences(defaults: defaults)
        #expect(repaired.changeBackgroundHex == "#FFF2A8")
        #expect(repaired.changeTextHex == nil)
    }

    @Test("旧版の常に固定の記録は常に出すとして読む")
    func migratesPinnedDefault() {
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "defaultMenuPinned")
        #expect(AppPreferences(defaults: suite.defaults).defaultBandVisibility == .always)
    }

    @Test("旧版で固定しないと決めていた記録は、乗せたときだけのまま読む")
    func keepsUnpinnedRecord() {
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(false, forKey: "defaultMenuPinned")
        #expect(AppPreferences(defaults: suite.defaults).defaultBandVisibility == .onHover)
    }

    @Test("新しい設定を選んだあとは旧版の記録より優先する")
    func newChoiceWinsOverPinnedRecord() {
        let suite = BandTestDefaultsSuite()
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

    /// Puts the window where it has room on every side, small enough for a small CI display: a window that reaches
    /// past the screen is moved back onto it, which would hide what the toolbar change itself does.
    private func place(_ window: NSWindow, band: CGFloat, model: DocumentViewModel) throws {
        let visible = try #require(window.screen?.visibleFrame)
        let content = window.contentRect(forFrameRect: window.frame)
        let paperHeight = content.height - band
        let scale = min(1, 400 / paperHeight)
        window.setContentSize(
            CGSize(width: (content.width * scale).rounded(), height: (paperHeight * scale).rounded() + band))
        model.windowDidEndLiveResize()
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 80))
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
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        let room: CGFloat = arrangement == .split ? Self.top + Self.bottom : Self.top
        try place(window, band: room, model: model)
        let pinned = window.contentRect(forFrameRect: window.frame)
        let paper = CGSize(width: pinned.width, height: pinned.height - room)
        let paperTop = pinned.maxY - Self.top

        model.isBandAlwaysVisible = false
        let off = window.contentRect(forFrameRect: window.frame)
        #expect(abs(off.width - paper.width) <= 3)
        #expect(abs(off.height - paper.height) <= 3)
        #expect(abs(off.maxY - paperTop) <= 3)
        try await waitUntil { abs((paperViewHeight(in: window) ?? 0) - off.height) <= 3 }

        model.isBandAlwaysVisible = true
        let on = window.contentRect(forFrameRect: window.frame)
        #expect(abs(on.height - paper.height - room) <= 3)
        #expect(abs(on.maxY - Self.top - paperTop) <= 3)
        try await waitUntil { abs((paperViewHeight(in: window) ?? 0) - paper.height) <= 3 }
    }

    /// Where the paper view stands on the screen.
    private func paperOnScreen(in window: NSWindow) -> CGRect? {
        func find(_ view: NSView) -> NSView? {
            if view is PaperPDFView { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let content = window.contentView, let paper = find(content) else { return nil }
        return window.convertToScreen(paper.convert(paper.bounds, to: nil))
    }

    private func isClose(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 && abs(a.width - b.width) <= 3
            && abs(a.height - b.height) <= 3
    }

    @Test(
        "ポインタで出した帯は窓を帯の分だけ外へ伸ばし、紙の画面上の位置と大きさを変えず、隠すと元に戻る",
        arguments: MenuArrangement.allCases)
    func hoverBandsTakeRoomWhileShown(arrangement: MenuArrangement) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = arrangement
        environment.preferences.defaultBandVisibility = .onHover
        let model = environment.model(TestFixtures.pdf("Hover"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: 0, model: model)
        let paperOnly = window.contentRect(forFrameRect: window.frame)
        try await waitUntil { abs((paperOnScreen(in: window)?.height ?? 0) - paperOnly.height) <= 3 }
        let paper = paperOnScreen(in: window)
        let bottom: CGFloat = arrangement == .split ? Self.bottom : 0

        model.bandRevealDidChange(true)
        let grown = window.contentRect(forFrameRect: window.frame)
        #expect(abs(grown.maxY - paperOnly.maxY - Self.top) <= 3)
        #expect(abs(paperOnly.minY - grown.minY - bottom) <= 3)
        #expect(abs(grown.width - paperOnly.width) <= 3)
        try await waitUntil { isClose(paperOnScreen(in: window), paper) }
        #expect(abs((model.currentPaperSize?.height ?? 0) - paperOnly.height) <= 3)

        model.bandRevealDidChange(false)
        let back = window.contentRect(forFrameRect: window.frame)
        #expect(abs(back.maxY - paperOnly.maxY) <= 3 && abs(back.minY - paperOnly.minY) <= 3)
        try await waitUntil { isClose(paperOnScreen(in: window), paper) }
    }

    @Test("ポインタで出した帯が場所を取ったまま刷り台へ入っても、戻ると窓は紙だけに戻り紙は動かない")
    func revealedRoomSurvivesStage() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultBandVisibility = .onHover
        let model = environment.model(Data("# Stage".utf8), format: .markdown)
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: 0, model: model)
        let paperOnly = window.contentRect(forFrameRect: window.frame)
        model.bandRevealDidChange(true)
        #expect(model.currentBandRoom != BandRoom())
        model.enterPrintMode()
        model.exitPrintMode()
        try await waitUntil {
            let content = window.contentRect(forFrameRect: window.frame)
            return model.mode == .view && abs(content.height - paperOnly.height) <= 3
                && abs(content.maxY - paperOnly.maxY) <= 3
        }
        #expect(model.currentBandRoom == BandRoom())
    }

    @Test("ツールバーを常に表示しているときは、ポインタで帯が出ても窓は変わらない")
    func alwaysShownBandsKeepWindow() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultBandVisibility = .always
        let model = environment.model(TestFixtures.pdf("Always"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: Self.top + Self.bottom, model: model)
        let frame = window.frame
        model.bandRevealDidChange(true)
        #expect(window.frame == frame)
        model.bandRevealDidChange(false)
        #expect(window.frame == frame)
    }

    /// The window's pointer tracker, which tests feed with a pointer place of their own.
    private func pointerTracker(in window: NSWindow) -> PointerTracker.TrackerView? {
        func find(_ view: NSView) -> PointerTracker.TrackerView? {
            if let tracker = view as? PointerTracker.TrackerView { return tracker }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    @MainActor private struct HoverWindow {
        let model: DocumentViewModel
        let controller: MemoryDocumentWindowController
        let window: NSWindow
        let paperOnly: CGRect
    }

    private func hoverWindow(_ environment: Environment, arrangement: MenuArrangement) async throws -> HoverWindow {
        environment.preferences.menuArrangement = arrangement
        environment.preferences.defaultBandVisibility = .onHover
        let model = environment.model(TestFixtures.pdf("Hover"))
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        var handedOff = false
        defer {
            if !handedOff {
                controller.close()
            }
        }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: 0, model: model)
        let paperOnly = window.contentRect(forFrameRect: window.frame)
        try await waitUntil { abs((paperOnScreen(in: window)?.height ?? 0) - paperOnly.height) <= 3 }
        handedOff = true
        return HoverWindow(model: model, controller: controller, window: window, paperOnly: paperOnly)
    }

    @Test("帯が出たまま上だけと上下を切り替えても、帯の場所は新しい組み方に合い、紙は画面の上で動かない")
    func arrangementChangeWhileShown() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let hover = try await hoverWindow(environment, arrangement: .top)
        defer {
            hover.model.stop()
            hover.controller.close()
        }
        let window = hover.window
        let paper = paperOnScreen(in: window)
        hover.model.bandRevealDidChange(true)
        #expect(hover.model.currentBandRoom == BandRoom(top: Self.top, bottom: 0))

        environment.preferences.menuArrangement = .split
        try await waitUntil { hover.model.currentBandRoom == BandRoom(top: Self.top, bottom: Self.bottom) }
        try await waitUntil {
            let content = window.contentRect(forFrameRect: window.frame)
            return abs(hover.paperOnly.minY - content.minY - Self.bottom) <= 3
                && abs(content.maxY - hover.paperOnly.maxY - Self.top) <= 3
        }
        try await waitUntil { isClose(paperOnScreen(in: window), paper) }

        environment.preferences.menuArrangement = .top
        try await waitUntil { hover.model.currentBandRoom == BandRoom(top: Self.top, bottom: 0) }
        try await waitUntil {
            let content = window.contentRect(forFrameRect: window.frame)
            return abs(content.minY - hover.paperOnly.minY) <= 3
                && abs(content.maxY - hover.paperOnly.maxY - Self.top) <= 3
        }
        try await waitUntil { isClose(paperOnScreen(in: window), paper) }
    }

    @Test("フルスクリーンの間は帯の場所で窓の枠を変えず、抜けると帯の今の場所に合わせる")
    func fullScreenLeavesFrameAlone() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let hover = try await hoverWindow(environment, arrangement: .split)
        defer {
            hover.model.stop()
            hover.controller.close()
        }
        let window = hover.window
        let model = hover.model
        model.bandRevealDidChange(true)
        let grown = window.frame
        let paperSize = model.currentPaperSize

        model.windowWillEnterFullScreen()
        model.showsOnAllSpaces = true
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(model.currentBandRoom == BandRoom())
        model.bandRevealDidChange(true)
        model.bandRevealDidChange(false)
        model.sizeWindowToPaper(keepHeight: true)
        #expect(window.frame == grown)
        #expect(model.currentPaperSize == paperSize)

        // The system gives back the frame from before, which still holds the room the bands had then.
        model.windowDidExitFullScreen()
        try await waitUntil { window.collectionBehavior.contains([.fullScreenAuxiliary, .canJoinAllSpaces]) }
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        try await waitUntil {
            let back = window.contentRect(forFrameRect: window.frame)
            return abs(back.height - hover.paperOnly.height) <= 3 && abs(back.maxY - hover.paperOnly.maxY) <= 3
        }
    }

    @Test("止まったポインタを紙の上端に置くと、帯が出て窓が伸び、隠す時間を過ぎても帯と窓の枠は変わらない")
    func stillPointerKeepsBandAndFrame() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let hover = try await hoverWindow(environment, arrangement: .split)
        defer {
            hover.model.stop()
            hover.controller.close()
        }
        let window = hover.window
        let tracker = try #require(pointerTracker(in: window))
        #expect(tracker.isMonitoring)
        // On the paper's top edge, where a hidden top band shows.
        tracker.debugMouseLocation = NSPoint(x: hover.paperOnly.midX, y: hover.paperOnly.maxY - 10)
        try await waitUntil { hover.model.currentBandRoom.top == Self.top }
        let shown = window.frame
        try await Task.sleep(for: .milliseconds(1500))
        #expect(window.frame == shown)
        #expect(hover.model.currentBandRoom.top == Self.top)
        // Away in the middle of the paper, the bands hide a moment later and give the room back.
        tracker.debugMouseLocation = NSPoint(x: hover.paperOnly.midX, y: hover.paperOnly.midY)
        try await waitUntil { hover.model.currentBandRoom == BandRoom() }
        let back = window.contentRect(forFrameRect: window.frame)
        #expect(abs(back.maxY - hover.paperOnly.maxY) <= 3)
    }

    @Test("ポインタの監視は窓に載っている間だけで、窓から外れると止まり、常に表示では張らない")
    func trackerStopsWithWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        defer { controller.close() }
        let tracker = PointerTracker.TrackerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        #expect(!tracker.isMonitoring)
        window.contentView?.addSubview(tracker)
        #expect(tracker.isMonitoring)
        tracker.isActive = false
        #expect(!tracker.isMonitoring)
        tracker.isActive = true
        #expect(tracker.isMonitoring)
        tracker.removeFromSuperview()
        #expect(!tracker.isMonitoring)
        #expect(tracker.trackingAreas.isEmpty)
    }

    @Test("窓の上に伸ばす余地がないと上の帯は紙に重ね、下に余地があれば下の帯だけ場所を取る")
    func hoverBandsOverlayWithoutRoom() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultBandVisibility = .onHover
        let model = environment.model(TestFixtures.pdf("Edge"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: 0, model: model)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY))
        let paperOnly = window.contentRect(forFrameRect: window.frame)
        model.bandRevealDidChange(true)
        let grown = window.contentRect(forFrameRect: window.frame)
        #expect(abs(grown.maxY - paperOnly.maxY) <= 3)
        #expect(abs(paperOnly.minY - grown.minY - Self.bottom) <= 3)
        #expect(model.currentBandRoom == BandRoom(top: 0, bottom: Self.bottom))
    }

    @Test("上に伸ばす余地のない窓で、上だけの帯を出したまま上下に変えると、下の帯だけ場所を取る")
    func arrangementChangeWithoutRoomAbove() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .top
        environment.preferences.defaultBandVisibility = .onHover
        let model = environment.model(TestFixtures.pdf("EdgeTop"))
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: 0, model: model)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY))
        let paperOnly = window.contentRect(forFrameRect: window.frame)
        // The top band is out over the paper: there is no room above to give it.
        model.bandRevealDidChange(true)
        #expect(model.currentBandRoom == BandRoom())

        environment.preferences.menuArrangement = .split
        try await waitUntil { model.currentBandRoom == BandRoom(top: 0, bottom: Self.bottom) }
        try await waitUntil {
            let content = window.contentRect(forFrameRect: window.frame)
            return abs(content.maxY - paperOnly.maxY) <= 3 && abs(paperOnly.minY - content.minY - Self.bottom) <= 3
        }
    }

    @Test(
        "刷り台や見比べ台でツールバーを切り替えて戻っても、紙の大きさと上端は変わらない",
        arguments: [false, true], BandVisibility.allCases)
    func toolbarToggledOnStage(compare: Bool, initial: BandVisibility) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.defaultBandVisibility = initial
        let model = environment.model(Data("# Stage".utf8), format: .markdown)
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        try place(window, band: model.isBandAlwaysVisible ? Self.top + Self.bottom : 0, model: model)
        func paper() -> CGRect {
            let content = window.contentRect(forFrameRect: window.frame)
            let top: CGFloat = model.isBandAlwaysVisible ? Self.top : 0
            let bottom: CGFloat = model.isBandAlwaysVisible ? Self.bottom : 0
            return CGRect(
                x: content.minX, y: content.minY + bottom, width: content.width,
                height: content.height - top - bottom)
        }
        let before = paper()

        if compare { model.enterCompareMode() } else { model.enterPrintMode() }
        #expect(model.mode == (compare ? .compare : .print))
        model.isBandAlwaysVisible.toggle()
        model.exitPrintMode()
        try await waitUntil { model.mode == .view && abs(paper().width - before.width) <= 3 }
        try await waitUntil { abs(paper().height - before.height) <= 3 && abs(paper().maxY - before.maxY) <= 3 }
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
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 80))
        // As the reader drags the window's corner narrower; the app then settles on the paper's exact height.
        var frame = window.frame
        frame.size.width -= 60
        window.setFrame(frame, display: true)
        model.windowDidEndLiveResize()
        let room: CGFloat = arrangement == .split ? Self.top + Self.bottom : Self.top
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
        defer { controller.close() }
        let window = try #require(controller.window)
        try await open(model)
        model.sizeWindowToPaper(initialOnly: true)
        let unit = try #require(model.paperUnitSize)
        let paper = ViewerWindow.initialPaperSize(unit: unit, on: window.screen)
        #expect(abs(window.contentRect(forFrameRect: window.frame).height - paper.height - Self.top) <= 1)
        // Room below the window, or it would be moved to stay on the screen.
        let visible = try #require(window.screen?.visibleFrame)
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
        let top = window.frame.maxY
        environment.preferences.menuArrangement = .split
        try await waitUntil {
            abs(window.contentRect(forFrameRect: window.frame).height - paper.height - Self.top - Self.bottom) <= 1
        }
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
        defer { controller.close() }
        let window = try #require(controller.window)
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
        defer { controller.close() }
        let window = try #require(controller.window)
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

    @Test("表示モードの用紙の系列は冊子の刷り方を保って切り替わり、文書に記録される")
    func paperSeriesChangesLayout() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let data = Data("# 見出し\n\n本文".utf8)
        let first = environment.model(data, format: .markdown)
        try await open(first)
        #expect(first.offersPaperSeries)
        first.layoutID = PrintLayout.a4BookletA5.id
        first.choosePaperSeries(.b)
        #expect(first.layoutID == PrintLayout.b5BookletB6.id)
        #expect(first.renderSettings?.layout == .b5BookletB6)
        #expect(first.rememberedSettings.layoutID == PrintLayout.b5BookletB6.id)
        first.rememberedSettingsDidChange()
        try await waitUntil { first.hasSavedSettings }
        first.stop()
        let second = environment.model(data, format: .markdown)
        defer { second.stop() }
        try await open(second)
        #expect(second.trayPaperSeries == .b)
        #expect(second.layoutID == PrintLayout.b5BookletB6.id)
        #expect(second.renderSettings?.layout == .b5BookletB6)
    }

    @Test("冊子の論理ページと余白と仕上げは表示・刷り台・見比べ台で同じ")
    func modesShareBookletLayout() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文".utf8), format: .markdown)
        defer { model.stop() }
        model.layoutID = PrintLayout.a4BookletA5.id
        model.printOptions.mirrorsMargins = true
        model.printFinish.breaks.h1 = .rightPage
        model.printFinish.toc.mode = .front
        let reading = try #require(model.renderSettings)
        #expect(reading.layout == .a4BookletA5)
        model.mode = .print
        #expect(model.renderSettings == reading)
        model.mode = .compare
        #expect(model.renderSettings == reading)
    }

    @Test("ノートのない冊子は表示と刷り台の往復で読んでいるページを変えない")
    func bookletKeepsReadingPosition() {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文".utf8), format: .markdown)
        defer { model.stop() }
        model.layoutID = PrintLayout.a4BookletA5.id
        model.currentPageIndex = 5
        model.enterPrintMode()
        #expect(model.currentPageIndex == 5)
        model.exitPrintMode()
        #expect(model.currentPageIndex == 5)
    }

    @Test("同梱見本と実文書の見本は冊子の論理ページと用紙の向きに従う")
    func samplesFollowPrintPaper() throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文".utf8), format: .markdown)
        defer { model.stop() }
        model.layoutID = PrintLayout.letterBookletHalfLetter.id
        model.paperOrientation = .landscape
        for mode in [ViewerMode.view, .print, .compare] {
            model.mode = mode
            let specimen = try #require(model.specimenSamples.inputs().settings)
            let document = try #require(model.themeSamples.inputs().settings)
            #expect(specimen.layout == .letterBookletHalfLetter)
            #expect(document.layout == .letterBookletHalfLetter)
            #expect(specimen.paperOrientation == .landscape)
            #expect(document.paperOrientation == .landscape)
        }
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
        #expect(!BandLayout.Item.applicable(for: pdf).contains(.paperSeries))
    }

    @Test("文字の文書を含む合本には紙の判の切り替えを出し、PDF だけの合本には出さない")
    func binderPaperSeries() {
        let environment = Environment()
        defer { environment.cleanUp() }
        func binderModel(_ names: [String]) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: Data(), fileURL: nil, format: .pdf, preferences: environment.preferences,
                library: environment.library,
                binder: BinderModel(
                    urls: names.map { environment.directory.appendingPathComponent($0) }, read: { _, _ in Data() }))
            model.isolateBandTestOutput()
            return model
        }
        let text = binderModel(["a.md", "b.pdf"])
        let pdfs = binderModel(["a.pdf", "b.pdf"])
        defer {
            text.stop()
            pdfs.stop()
        }
        #expect(text.offersPaperSeries)
        #expect(!pdfs.offersPaperSeries)
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

    @Test("最初の章より前は今の章の題名が空でも部品を置ける")
    func beforeFirstChapter() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(
            Data("# First Chapter\n\nbody\n\n# Second Chapter\n\nbody".utf8), format: .markdown,
            pages: TestFixtures.textPDF(["Cover", "First Chapter", "Second Chapter"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { !model.outlineEntries.isEmpty }
        model.viewOptions.layout = .single
        model.currentPageIndex = 0
        #expect(BandLayout.Item.applicable(for: model).contains(.chapter))
        #expect(model.currentChapterTitle.isEmpty)
        #expect(!BandLayout.Item.chapter.hasCompactForm)
    }

    @Test("刷り台で冊子に組み直して表示へ戻ると、組み直さなくても目次は冊子のページを指す", .timeLimit(.minutes(1)))
    func outlineFollowsTrayLayout() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        // A5 pages hold less, so the second chapter starts later than on A4.
        let renderer = DocumentRenderer(paginate: { request in
            let pages =
                request.pageSize.width < 450
                ? ["First Chapter", "Body", "Body", "Body", "Second Chapter"]
                : ["First Chapter", "Body", "Second Chapter"]
            return try #require(PDFDocument(data: TestFixtures.textPDF(pages)))
        })
        let model = DocumentViewModel(
            data: Data("# First Chapter\n\nbody\n\n# Second Chapter\n\nbody".utf8), fileURL: nil,
            format: .markdown, preferences: environment.preferences, library: environment.library,
            renderer: renderer, settingsStore: environment.store)
        model.isolateBandTestOutput()
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.outlineEntries.last?.pageIndex == 2 }

        model.enterPrintMode()
        model.layoutID = PrintLayout.a4BookletA5.id
        model.render()
        try await waitUntil { !model.isRendering }
        model.exitPrintMode()
        #expect(model.mode == .view)
        #expect(model.isUpToDate)
        try await waitUntil { model.outlineEntries.last?.pageIndex == 4 }
        #expect(
            model.outlineEntries == [
                OutlineEntry(level: 1, title: "First Chapter", pageIndex: 0),
                OutlineEntry(level: 1, title: "Second Chapter", pageIndex: 4),
            ])
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

    @Test("見出しのない一ページの文書には目次を出さない")
    func singlePageWithoutHeadings() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data("本文だけ".utf8), format: .markdown, pages: TestFixtures.pdf("Single", pages: 1))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.documentStatistics != nil }
        #expect(!model.hasOutline)
        #expect(!BandLayout.Item.applicable(for: model).contains(.chapter))
        #expect(!BandLayout.Item.applicable(for: model).contains(.outline))
    }

    @Test("帯から外す設定では目次の部品を帯に置かず、「…」から開ける")
    func outlineCanLeaveTheBand() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.showsOutlineOnBand = false
        let model = environment.model(
            Data("# First Chapter".utf8), format: .markdown, pages: TestFixtures.textPDF(["First Chapter"]))
        defer { model.stop() }
        try await open(model)
        try await waitUntil { model.hasOutline }
        let plans = BandPlans(model: model, menu: OverlayMenuState())
        #expect(plans.band(of: .outline) == nil)
        #expect(plans.resolved.unusedAvailable.contains(.outline))
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
    func choosingEntryClosesPopover() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(TestFixtures.pdf("Choose"))
        defer { model.stop() }
        try await open(model)
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

    @Test("ページ送りは 2 ページ以上の文書で使え、標準では上下分割の下の帯にだけ置き、上だけでは「…」に入る")
    func pageTurnNeedsPagesAndSplit() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.model(TestFixtures.pdf("Turn"))
        defer { model.stop() }
        #expect(!BandLayout.Item.applicable(for: model).contains(.pageTurn))
        try await open(model)
        #expect(BandLayout.Item.applicable(for: model).contains(.pageTurn))
        #expect(BandPlans(model: model, menu: OverlayMenuState()).band(of: .pageTurn) == .bottom)
        environment.preferences.menuArrangement = .top
        #expect(BandLayout.Item.applicable(for: model).contains(.pageTurn))
        let top = BandPlans(model: model, menu: OverlayMenuState())
        #expect(top.band(of: .pageTurn) == nil)
        #expect(top.resolved.unusedAvailable.contains(.pageTurn))
    }
}
