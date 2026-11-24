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
        let renderer = DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: TestFixtures.textPDF(["Bar"])))
        })
        let model = DocumentViewModel(
            data: Data("# Top bar\n\nText.".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        // Nothing here may reach a printer or a save panel.
        model.printSubmit = { _, _, _ in Issue.record("A print job was submitted") }
        model.outputOverride = { _, _ in Issue.record("An output was started") }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        var handedOff = false
        defer {
            if !handedOff {
                controller.close()
                try? FileManager.default.removeItem(at: directory)
                suite.remove()
            }
        }
        let window = try #require(controller.window)
        controller.showWindow(nil)
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        if compare { model.enterCompareMode() } else { model.enterPrintMode() }
        // The stage takes its toolbar and its frame after the mode changes; the view mode's views must be gone.
        try await Task.sleep(for: .milliseconds(800))
        // A refused entry would leave the view mode, where the click test's "back to the view" is already true.
        try #require(model.mode == (compare ? .compare : .print))
        handedOff = true
        return Screen(model: model, controller: controller, window: window, directory: directory, suite: suite)
    }

    /// The window's root view, which holds the title bar in front of the content.
    private func root(of window: NSWindow) -> NSView? {
        var view = window.contentView
        while let parent = view?.superview { view = parent }
        return view
    }

    /// At rest Sequoia's frame view reports NSToolbarView even over working controls. A responder placed
    /// in the content plane (under the real title bar) records where the window actually sends mouseDown.
    private final class ClickProbe: NSView {
        var received: NSPoint?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { received = event.locationInWindow }
        override func mouseUp(with event: NSEvent) {}
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
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }
        let frameView = try #require(root(of: window))
        let height = frameView.bounds.height
        #expect(
            lights.centerY == PrintTopBar.height / 2,
            "centerY=\(lights.centerY), barHeight=\(PrintTopBar.height), buttons=\(buttons), rootHeight=\(height), contentLayout=\(window.contentLayoutRect), toolbarStyle=\(window.toolbarStyle.rawValue)"
        )
        let content = try #require(window.contentView)
        let bar = CGRect(x: 0, y: height - PrintTopBar.height, width: window.frame.width, height: PrintTopBar.height)
        let probe = ClickProbe(frame: content.convert(bar, from: nil))
        content.addSubview(probe, positioned: .above, relativeTo: nil)
        defer { probe.removeFromSuperview() }
        let center = NSPoint(x: bar.midX, y: bar.midY)
        let parent = try #require(content.superview)
        try #require(content.hitTest(parent.convert(center, from: nil)) === probe, "本文側で押下を記録できる検査窓")
        var taken: [NSPoint] = []
        // Probe the usable interior, including the space on both sides of the traffic lights and between
        // controls. The top and side resize borders and the rounded window corners aren't content buttons:
        // macOS 26 keeps a few points at the top and up to 8pt at the sides (more along the corner arcs) for
        // resizing, and no control of the bar reaches that close to the window's edge.
        for y in stride(from: bar.minY + 3, through: bar.maxY - 8, by: 3) {
            for x in stride(from: 10.0, through: bar.maxX - 10, by: 2) {
                let point = NSPoint(x: x, y: y)
                guard !buttons.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { continue }
                // The frame keeps a band along the rounded top corners for corner resizing.
                let radius = 32.0
                let centerX = x < radius ? radius : (x > bar.maxX - radius ? bar.maxX - radius : x)
                if y > height - radius, hypot(x - centerX, y - (height - radius)) > radius - 10 { continue }
                // On the newer systems the frame already returns the content responder across the bar.
                // Reserve event tracking for points whose raw hit doesn't establish that.
                if #available(macOS 26, *), frameView.hitTest(point) === probe { continue }
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                            pressure: type == .leftMouseDown ? 1 : 0))
                }
                probe.received = nil
                // A real obstruction may track synchronously in mouseDown. Queue its matching release first;
                // if the probe received the down, deliver the queued release before testing the next point.
                let down = try event(.leftMouseDown)
                let up = try event(.leftMouseUp)
                window.postEvent(up, atStart: true)
                NSApp.sendEvent(down)
                if let next = NSApp.nextEvent(
                    matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
                    next.timestamp == up.timestamp && next.windowNumber == window.windowNumber,
                    let release = NSApp.nextEvent(
                        matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(release)
                }
                if probe.received != point { taken.append(point) }
            }
        }
        if let point = taken.first {
            let hit = root(of: window)?.hitTest(point)
            Issue.record("本文に押下が届かなかった点は \(taken.count) 個、先頭 \(taken.prefix(10))、ビュー \(String(describing: hit))")
        }
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
        try TestWindowMouse.click(at: point, in: window)
        try await waitUntil { screen.model.mode == .view }
    }
}
