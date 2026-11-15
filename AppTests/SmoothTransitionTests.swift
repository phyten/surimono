import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// Counts the frames set on a window, whichever way the app sets them.
@MainActor
private final class FrameCountingWindow: NSWindow {
    var frameChanges = 0

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        frameChanges += 1
        super.setFrame(frameRect, display: flag)
    }
}

/// Holds a composition until the test lets it go.
@MainActor
private final class Gate {
    var holds = true
}

@MainActor
struct SmoothTransitionTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let library: UserLibrary

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: root)
        }

        deinit {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func visibleWindow(width: CGFloat, height: CGFloat) -> FrameCountingWindow {
        let window = FrameCountingWindow(
            contentRect: NSRect(x: 200, y: 150, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// Lays out the pages at the size asked for, without WebKit.
    private func renderer() -> DocumentRenderer {
        DocumentRenderer(paginate: { request in
            try #require(PDFDocument(data: Self.pdf(size: request.pageSize, pages: 4)))
        })
    }

    private static func pdf(size: CGSize, pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    private func render(_ model: DocumentViewModel) async throws {
        model.render()
        try await waitUntil { !model.isRendering }
        try #require(model.error == nil)
        try #require(model.isUpToDate)
    }

    @Test("見えている窓でも、刷り台への出入りで枠は一度ずつ、その場で変わる")
    func stageFrameChangesOnceEachWay() {
        let window = visibleWindow(width: 500, height: 400)
        defer { window.close() }
        let original = window.frame
        window.frameChanges = 0
        PrintModeWindow.enter(window)
        #expect(window.frame.size == NSSize(width: 760, height: 560))
        #expect(window.frameChanges == 1)
        var completed = false
        PrintModeWindow.exit(window) { completed = true }
        #expect(completed)
        #expect(window.frame == original)
        #expect(window.frameChanges == 2)
    }

    @Test("刷り台で紙の形が変わっても、表示に戻った時点で窓は新しい紙の形になっている", .timeLimit(.minutes(1)))
    func returnTakesTheNewShapeAtOnce() async throws {
        let fixture = Fixture()
        let model = DocumentViewModel(
            data: Data("# Window fixture".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library, renderer: renderer())
        defer { model.stop() }
        model.setLayout(.single)
        model.paperOrientation = .landscape
        try await render(model)
        // Smaller than the tray, so that the tray enlarges the window and the way back restores it.
        let window = visibleWindow(width: 600, height: 424)
        defer { window.close() }
        model.window = window
        model.sizeWindowToPaper()
        ViewerWindow.setPaperSize(CGSize(width: 600, height: 424), band: 0, of: window, animate: false)
        model.enterPrintMode()
        #expect(window.frame.size == NSSize(width: 760, height: 560))
        model.chooseLayout(PrintLayout.letterBookletHalfLetter.id)
        try await render(model)
        model.exitPrintMode()
        // Nothing is left to wait for: the window is back, at the height it had and in the new paper's shape.
        #expect(model.mode == .view)
        // The bands keep their room of the 424 (70pt on macOS 26); Half Letter is 396 × 612.
        let paperHeight = 424 - BandRoom.full(for: .split).total
        #expect(window.frame.size == CGSize(width: (paperHeight * 396 / 612).rounded(), height: 424))
    }

    @Test("新しいレイアウトの用紙を組む間も、刷り台は前の用紙を見せ続ける", .timeLimit(.minutes(1)))
    func trayKeepsItsSheetsWhileComposing() async throws {
        let fixture = Fixture()
        let renderer = renderer()
        let model = DocumentViewModel(
            data: Data("# Tray fixture".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library, renderer: renderer)
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        try #require(model.hasCurrentPrintPreview)
        let before = try #require(model.printTray)
        let gate = Gate()
        renderer.willComposeSheet = {
            while gate.holds { try await Task.sleep(for: .milliseconds(10)) }
        }
        model.chooseLayout(PrintLayout.a4BookletA5.id)
        model.render()
        // The new logical pages are out; their sheets are not.
        try await waitUntil { model.result?.layout.id == PrintLayout.a4BookletA5.id }
        #expect(!model.hasCurrentPrintPreview)
        #expect(model.showsTrayPreview)
        #expect(model.printTray?.layout == before.layout)
        #expect(!model.canOutput)
        gate.holds = false
        try await waitUntil { !model.isRendering }
        #expect(model.hasCurrentPrintPreview)
        #expect(model.showsTrayPreview)
        #expect(model.printTray?.layout.id == PrintLayout.a4BookletA5.id)
    }

    @Test("用紙を組めなかったときは、前の用紙を見せたままにしない", .timeLimit(.minutes(1)))
    func failedCompositionHidesTheOldSheets() async throws {
        let fixture = Fixture()
        let renderer = renderer()
        let model = DocumentViewModel(
            data: Data("# Tray fixture".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library, renderer: renderer)
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        renderer.willComposeSheet = { throw DocumentRenderer.RenderingError.invalidPDF }
        model.chooseLayout(PrintLayout.a4BookletA5.id)
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.error != nil)
        #expect(!model.showsTrayPreview)
    }

    @Test("一枚の文書の窓へのドラッグでは帯を出さず、一覧のある窓へのドラッグでは一覧のボタンのために出す")
    func dragHoldsTheBandOnlyForAList() throws {
        let fixture = Fixture()
        let own = fixture.root.appendingPathComponent("own.pdf")
        let other = fixture.root.appendingPathComponent("other.pdf")
        let document = DocumentViewModel(
            data: Data(), fileURL: own, format: .pdf, preferences: fixture.preferences, library: fixture.library)
        #expect(document.dragEntered([other], at: .zero))
        #expect(document.drop.isActive)
        #expect(!document.drop.holdsBand)
        let binder = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf, preferences: fixture.preferences, library: fixture.library,
            binder: BinderModel(urls: [own]))
        #expect(binder.dragEntered([other], at: .zero))
        #expect(binder.drop.holdsBand)
    }

    @Test("ドラッグの間に出た帯は紙の上に重ね、窓を伸ばさない", .timeLimit(.minutes(1)))
    func dragDoesNotGrowTheWindow() async throws {
        let fixture = Fixture()
        let model = DocumentViewModel(
            data: try Self.pdf(size: CGSize(width: 600, height: 800), pages: 1),
            fileURL: fixture.root.appendingPathComponent("own.pdf"), format: .pdf,
            preferences: fixture.preferences, library: fixture.library)
        defer { model.stop() }
        model.bandVisibility = .onHover
        try await render(model)
        let window = FrameCountingWindow(
            contentRect: NSRect(x: 200, y: 150, width: 300, height: 400),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        model.window = window
        model.sizeWindowToPaper()
        // Small and low on the screen, so that a band shown by the pointer has room to grow the window.
        ViewerWindow.setPaperSize(CGSize(width: 300, height: 400), band: 0, of: window, animate: false)
        let frame = window.frame
        #expect(model.dragEntered([fixture.root.appendingPathComponent("other.pdf")], at: .zero))
        model.bandRevealDidChange(true)
        #expect(window.frame == frame)
        #expect(model.currentBandRoom == BandRoom())
        // Without a drag the same band takes its room beside the paper.
        model.drop.end()
        model.bandRevealDidChange(false)
        model.bandRevealDidChange(true)
        #expect(window.frame.height > frame.height)
    }

    /// A model on the print screen whose compositions wait while `gate` holds.
    private func heldModel(_ fixture: Fixture, gate: Gate, renderer: DocumentRenderer? = nil) -> DocumentViewModel {
        let renderer = renderer ?? self.renderer()
        renderer.willComposeSheet = {
            while gate.holds { try await Task.sleep(for: .milliseconds(10)) }
        }
        let model = DocumentViewModel(
            data: Data("# Tray fixture".utf8), fileURL: nil, format: .markdown,
            preferences: fixture.preferences, library: fixture.library, renderer: renderer)
        model.enterPrintMode()
        return model
    }

    @Test("前の用紙を見せている間、上のページ数とノートの数はどちらも前の用紙のものになる", .timeLimit(.minutes(1)))
    func pageCountsStayWithTheShownSheets() async throws {
        let fixture = Fixture()
        let gate = Gate()
        gate.holds = false
        let model = heldModel(fixture, gate: gate)
        defer { model.stop() }
        model.notes.isEnabled = true
        try await render(model)
        let before = try #require(model.trayPageCount)
        try #require(before.notes > 0)
        gate.holds = true
        model.notes.isEnabled = false
        model.render()
        // The pages without notes are laid out; their sheets are not composed yet.
        try await waitUntil { model.result.map { $0.plan.logicalPageCount != before.pages } ?? false }
        #expect(model.showsTrayPreview)
        #expect(model.trayPageCount?.pages == before.pages)
        #expect(model.trayPageCount?.notes == before.notes)
        gate.holds = false
        try await waitUntil { !model.isRendering }
        #expect(model.trayPageCount?.pages == model.result?.plan.logicalPageCount)
        #expect(model.trayPageCount?.notes == 0)
    }

    @Test("読めなくなった画像を読み直して組む間も、刷り台の名前は見せている用紙の画像のまま", .timeLimit(.minutes(1)))
    func imageNamesStayWithTheShownSheets() async throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let first = fixture.root.appendingPathComponent("A.png")
        let second = fixture.root.appendingPathComponent("B.png")
        try TestFixtures.png(red: 0.1).write(to: first)
        try TestFixtures.png(red: 0.2).write(to: second)
        let gate = Gate()
        gate.holds = false
        let renderer = DocumentRenderer()
        renderer.willComposeSheet = {
            while gate.holds { try await Task.sleep(for: .milliseconds(10)) }
        }
        let bundle = ImageBundleModel(urls: [first, second])
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: fixture.preferences, library: fixture.library,
            renderer: renderer, imageBundle: bundle)
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        #expect(model.trayImageNames == ["A.png", "B.png"])
        gate.holds = true
        try Data("not an image".utf8).write(to: first)
        bundle.clearCache()
        model.render()
        try await waitUntil { model.unreadableImageURLs.map(\.lastPathComponent) == ["A.png"] }
        // The sheets shown still have A on them, and so do their names.
        #expect(model.showsTrayPreview)
        #expect(model.trayImageNames == ["A.png", "B.png"])
        gate.holds = false
        try await waitUntil { !model.isRendering }
        #expect(model.trayImageNames == ["B.png"])
    }

    @Test("前の冊子の用紙を見せている間は折ってみるが効かず、Esc は刷り台を閉じるのに使われる", .timeLimit(.minutes(1)))
    func foldWaitsForCurrentSheets() async throws {
        let fixture = Fixture()
        let gate = Gate()
        gate.holds = false
        let model = heldModel(fixture, gate: gate)
        defer { model.stop() }
        model.chooseLayout(PrintLayout.a4BookletA5.id)
        try await render(model)
        #expect(model.canShowFold)
        gate.holds = true
        model.chooseLayout(PrintLayout.a4Single.id)
        model.render()
        try await waitUntil { model.result?.layout.id == PrintLayout.a4Single.id }
        // The booklet's sheets are still on the tray, with its button.
        #expect(model.printTray?.isBooklet == true)
        #expect(!model.canShowFold)
        model.showFold()
        #expect(!model.showsFold)
        #expect(model.printEscapeTarget == .screen)
        gate.holds = false
        try await waitUntil { !model.isRendering }
        // A fold left over from earlier ends once the sheets come out as no booklet.
        model.showsFold = true
        model.foldAvailabilityDidChange()
        #expect(!model.showsFold)
        #expect(model.printEscapeTarget == .screen)
    }

    @Test("組み直しの途中で画像を並べ替えると、前の用紙もその名前も見せない", .timeLimit(.minutes(1)))
    func reorderingHidesTheShownSheets() async throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let first = fixture.root.appendingPathComponent("1.png")
        let second = fixture.root.appendingPathComponent("2.png")
        try TestFixtures.png(red: 0.1).write(to: first)
        try TestFixtures.png(red: 0.2).write(to: second)
        let gate = Gate()
        gate.holds = false
        let renderer = DocumentRenderer()
        renderer.willComposeSheet = {
            while gate.holds { try await Task.sleep(for: .milliseconds(10)) }
        }
        let bundle = ImageBundleModel(urls: [first, second])
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: fixture.preferences, library: fixture.library,
            renderer: renderer, imageBundle: bundle)
        defer { model.stop() }
        model.enterPrintMode()
        try await render(model)
        gate.holds = true
        model.chooseLayout(PrintLayout.a4Duplex.id)
        model.render()
        try await waitUntil { model.result?.layout.id == PrintLayout.a4Duplex.id }
        #expect(model.showsTrayPreview)
        // Reordered while the sheets of the new layout are composed: the sheets shown are in the old order.
        bundle.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        model.listDidChange()
        #expect(!model.showsTrayPreview)
        #expect(model.trayImageNames == nil)
        gate.holds = false
        try await waitUntil { !model.isRendering }
        #expect(model.showsTrayPreview)
        #expect(model.trayImageNames == ["2.png", "1.png"])
    }
}
