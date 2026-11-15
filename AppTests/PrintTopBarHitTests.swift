import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// The print screen and the compare screen keep a toolbar for the title bar's height. The title bar is in front of
/// the content, so a toolbar item viewer over the top bar would take the clicks meant for its controls.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PrintTopBarHitTests {
    private struct Screen {
        let model: DocumentViewModel
        let controller: MemoryDocumentWindowController
        let window: NSWindow
        let directory: URL
        let suite: TestDefaultsSuite

        func close() {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func screen(compare: Bool) async throws -> Screen {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        let renderer = DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: TestFixtures.pdf("Bar"))) })
        let model = DocumentViewModel(
            data: Data("# Top bar\n\nText.".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        // Nothing here may reach a printer or a save panel.
        model.printSubmit = { _, _, _ in Issue.record("A print job was submitted") }
        model.outputOverride = { _, _ in Issue.record("An output was started") }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        let window = try #require(controller.window)
        controller.showWindow(nil)
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        if compare { model.enterCompareMode() } else { model.enterPrintMode() }
        // The stage takes its toolbar and its frame after the mode changes; the view mode's views must be gone.
        try await Task.sleep(for: .milliseconds(800))
        // A refused entry would leave the view mode, where the click test's "back to the view" is already true.
        try #require(model.mode == (compare ? .compare : .print))
        return Screen(model: model, controller: controller, window: window, directory: directory, suite: suite)
    }

    /// The window's root view, which holds the title bar in front of the content.
    private func root(of window: NSWindow) -> NSView? {
        var view = window.contentView
        while let parent = view?.superview { view = parent }
        return view
    }

    /// Whether the window's title bar takes a click at a point of the window (bottom-left origin): the title bar is in
    /// front of the content, and where it takes the click, the top bar's control under it never gets it.
    private func titleBarTakesClick(at point: NSPoint, in window: NSWindow) -> Bool {
        var view = root(of: window)?.hitTest(point)
        while let current = view {
            if String(describing: type(of: current)).contains("Titlebar") { return true }
            view = current.superview
        }
        return false
    }

    @Test("印刷画面と見比べ台の上のバーは、信号機のほかはどこもタイトルバーに取られない", arguments: [false, true])
    func titleBarLeavesTheBarToItsControls(compare: Bool) async throws {
        let screen = try await screen(compare: compare)
        defer { screen.close() }
        let window = screen.window
        #expect(window.frame.width == (compare ? 900 : 760))
        // The toolbar stays: it keeps the title bar as tall as the bar, with the traffic lights in its middle.
        #expect(window.toolbar != nil)
        let lights = try #require(TrafficLights(window: window))
        #expect(lights.centerY == PrintTopBar.height / 2)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
        let height = try #require(root(of: window)).bounds.height
        var taken: [NSPoint] = []
        for y in stride(from: height - PrintTopBar.height + 1, to: height, by: 3) {
            for x in stride(from: 1.0, to: window.frame.width, by: 2) {
                let point = NSPoint(x: x, y: y)
                guard !buttons.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { continue }
                if titleBarTakesClick(at: point, in: window) { taken.append(point) }
            }
        }
        #expect(taken.isEmpty, "The title bar takes \(taken.count) points, first \(String(describing: taken.first))")
    }

    @Test("「表示に戻る」は、ツールバーの項目が覆っていた左寄りの場所を押しても表示へ戻る", arguments: [false, true])
    func backToViewTakesTheClickNearTheTrafficLights(compare: Bool) async throws {
        let screen = try await screen(compare: compare)
        defer { screen.close() }
        let window = screen.window
        let lights = try #require(TrafficLights(window: window))
        let height = try #require(root(of: window)).bounds.height
        // "Back to View" starts 14pt after the green button. The placeholder's viewer stood 92…136pt from the window's
        // left edge, over the button's left part.
        let point = NSPoint(x: lights.titleLeading + 20, y: height - lights.centerY)
        #expect(point.x > 92 && point.x < 136)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        try await waitUntil { screen.model.mode == .view }
    }
}
