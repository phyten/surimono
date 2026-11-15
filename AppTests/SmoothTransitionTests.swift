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
}
