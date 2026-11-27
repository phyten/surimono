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
    @MainActor private struct Screen {
        let model: DocumentViewModel
        let controller: MemoryDocumentWindowController
        let window: NSWindow
        let directory: URL
        let suite: TestDefaultsSuite
        let focus: TestWindowMouse.Focus
        let readingToolbarStyle: NSWindow.ToolbarStyle

        func close() {
            controller.close()
            focus.restore()
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
    }

    private func waitUntil(
        _ detail: @autoclosure () -> String, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(detail())", sourceLocation: sourceLocation)
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
        let focus = TestWindowMouse.Focus()
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        var handedOff = false
        defer {
            if !handedOff {
                controller.close()
                focus.restore()
                try? FileManager.default.removeItem(at: directory)
                suite.remove()
            }
        }
        let window = try #require(controller.window)
        controller.showWindow(nil)
        model.start()
        try await waitUntil("組版完了") { model.result != nil && !model.isRendering }
        let readingToolbarStyle = window.toolbarStyle
        if compare { model.enterCompareMode() } else { model.enterPrintMode() }
        if #unavailable(macOS 26), !compare {
            let display = try #require(window.screen)
            var frame = window.frame
            frame.size = NSSize(width: 760, height: min(871, display.visibleFrame.height))
            frame.origin.x = min(max(frame.minX, display.visibleFrame.minX), display.visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, display.visibleFrame.minY), display.visibleFrame.maxY - frame.height)
            ViewerWindow.setStageFrame(frame, of: window)
        }
        try await waitUntil("画面の切替: \(Self.chrome(in: window)) \(TestWindowMouse.diagnostic(in: window))") {
            model.mode == (compare ? .compare : .print) && window.toolbar != nil
                && window.frame.width == (compare ? 900 : 760)
                && TrafficLights(window: window)?.centerY == PrintTopBar.height / 2
        }
        try await focus.prepare(window)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        handedOff = true
        return Screen(
            model: model, controller: controller, window: window, directory: directory, suite: suite, focus: focus,
            readingToolbarStyle: readingToolbarStyle)
    }

    private static func chrome(in window: NSWindow) -> String {
        let items = window.toolbar?.items.map { $0.itemIdentifier.rawValue }
        return "toolbar=\(String(describing: items)) style=\(window.toolbarStyle.rawValue) "
            + "lights=\(String(describing: TrafficLights(window: window)))"
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

    // Only after a real button failed: dispatch at the same point with a responder immediately below
    // the title bar, in the same window. A raw frame-view hit alone cannot identify the event recipient.
    private func probeAfterMiss(at point: NSPoint, in window: NSWindow) throws -> String {
        let content = try #require(window.contentView)
        let probe = ClickProbe(frame: content.bounds)
        content.addSubview(probe, positioned: .above, relativeTo: nil)
        defer { probe.removeFromSuperview() }
        try TestWindowMouse.click(at: point, in: window, queueRelease: true)
        return "本文側の対照点に mouseDown が届いた=\(probe.received == point)"
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
        // Include a control point well below the title bar to distinguish a blocked toolbar from
        // a host that cannot deliver synthetic clicks anywhere in this window.
        let probe = ClickProbe(frame: content.bounds)
        content.addSubview(probe, positioned: .above, relativeTo: nil)
        defer { probe.removeFromSuperview() }
        let center = NSPoint(x: bar.midX, y: bar.midY)
        let parent = try #require(content.superview)
        try #require(content.hitTest(parent.convert(center, from: nil)) === probe, "本文側で押下を記録できる検査窓")
        if #unavailable(macOS 26) {
            let control = NSPoint(x: bar.midX, y: bar.minY - 40)
            try TestWindowMouse.click(at: control, in: window, queueRelease: true)
            try #require(
                probe.received == control,
                "本文の対照点への押下: \(TestWindowMouse.diagnostic(in: window, at: control))")
        }
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
                probe.received = nil
                try TestWindowMouse.click(at: point, in: window, queueRelease: true)
                if probe.received != point { taken.append(point) }
            }
        }
        if let point = taken.first {
            Issue.record(
                "本文に押下が届かなかった点は \(taken.count) 個、先頭 \(taken.prefix(10))、\(TestWindowMouse.diagnostic(in: window, at: point))"
            )
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
        var point = NSPoint(x: lights.titleLeading + 20, y: height - lights.centerY)
        var buttonFrame: CGRect?
        if #unavailable(macOS 26) {
            let toolbar = try #require(window.toolbar)
            #expect(toolbar.items.isEmpty, "\(Self.chrome(in: window))")
            if !compare {
                // Reproduce the observed window-local position regardless of where the VM places the window.
                try #require(window.frame.width == 760)
                point = NSPoint(x: 100, y: height - 19)
                #if DEBUG
                    func marker(in view: NSView) -> NSView? {
                        if view is PrintBackButtonBounds.Marker { return view }
                        return view.subviews.lazy.compactMap { marker(in: $0) }.first
                    }
                    try await waitUntil(
                        "戻るボタンの配置: frame=\(String(describing: buttonFrame)), point=\(point), \(Self.chrome(in: window))"
                    ) {
                        guard let root = window.contentView, let view = marker(in: root) else { return false }
                        buttonFrame = view.convert(view.bounds, to: nil)
                        return buttonFrame?.contains(point) == true
                    }
                #endif
            }
        }
        #expect(point.x > 92 && point.x < 136)
        let before = TestWindowMouse.diagnostic(in: window, at: point)
        try TestWindowMouse.click(at: point, in: window)
        do {
            try await waitUntil(
                "表示へ戻る: button=\(String(describing: buttonFrame)) local=\(point), before=[\(before)], after=[\(TestWindowMouse.diagnostic(in: window, at: point))] \(Self.chrome(in: window))"
            ) { screen.model.mode == .view }
        } catch {
            if #unavailable(macOS 26) {
                let result = try probeAfterMiss(at: point, in: window)
                Issue.record("同じ窓の同じ点での再測定: \(result)")
            }
            throw error
        }
        if #unavailable(macOS 26) {
            try await waitUntil("表示用タイトルバーの復元: \(Self.chrome(in: window))") {
                window.toolbar == nil && window.toolbarStyle == screen.readingToolbarStyle
            }
        }
    }
}
