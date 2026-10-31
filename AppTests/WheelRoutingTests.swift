import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct WheelRoutingTests {
    @Test("単ページと見開きのホイールは選んだ効果で一度だけ送る", arguments: ViewOptions.Layout.allCases)
    func wheelUsesTransition(layout: ViewOptions.Layout) throws {
        let (view, window) = try paper(layout: layout)
        var turns = 0
        view.onTurn = { turns += 1 }
        let event = PaperWheelEvent()
        event.target = window
        for time in [0.0, 0.1] {
            event.time = time
            NSApplication.shared.sendEvent(event)
            #expect(turns == 0)
        }
        event.time = 0.2
        NSApplication.shared.sendEvent(event)
        #expect(turns == 1)
        #expect(view.currentPageIndex > 0)
        #expect((view.layer?.animation(forKey: "transition") as? CATransition)?.type == .moveIn)
        event.momentum = .changed
        event.time = 1
        #expect(view.handleWheelEvent(event))
        #expect(turns == 1)
        withExtendedLifetime(window) {}
    }

    @Test("連続表示と拡大中はPDFKitに任せ、コマンド付きホイールは拡大する")
    func wheelRouting() throws {
        let (view, window) = try paper(layout: .single)
        let event = PaperWheelEvent()
        event.target = window
        view.setZoom(2, anchor: nil)
        #expect(!view.handleWheelEvent(event))
        event.time = 1
        event.modifiers = .command
        event.travel = 10
        #expect(view.handleWheelEvent(event))
        #expect(view.zoom > 2)
        event.modifiers = []
        event.time = 2
        view.setZoom(1, anchor: nil)
        view.apply(ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false))
        #expect(!view.handleWheelEvent(event))
        event.target = nil
        #expect(!view.handleWheelEvent(event))
        withExtendedLifetime(window) {}
    }

    @Test("紙を覆うパネル上のホイールを取り込まない")
    func overlay() throws {
        let (view, window) = try paper(layout: .single)
        let content = NSView(frame: view.frame)
        window.contentView = content
        content.addSubview(view)
        content.addSubview(NSView(frame: NSRect(x: 0, y: 200, width: 200, height: 200)))
        let event = PaperWheelEvent()
        event.target = window
        #expect(!view.handleWheelEvent(event))
        withExtendedLifetime(window) {}
    }

    @Test(
        "パネル開始の慣性を紙が奪わず、紙開始の慣性はパネル上でも紙が受け持つ",
        arguments: [false, true])
    func momentumOwnership(startsOnPaper: Bool) throws {
        let (view, window) = try paper(layout: .single)
        let content = NSView(frame: view.frame)
        window.contentView = content
        content.addSubview(view)
        content.addSubview(NSView(frame: NSRect(x: 0, y: 200, width: 200, height: 200)))
        let event = PaperWheelEvent()
        event.target = window
        event.point = NSPoint(x: startsOnPaper ? 300 : 100, y: 300)
        event.gesture = .began
        #expect(view.handleWheelEvent(event) == startsOnPaper)
        event.time = 0.1
        event.gesture = .ended
        #expect(view.handleWheelEvent(event) == startsOnPaper)
        event.gesture = []
        event.point.x = startsOnPaper ? 100 : 300
        event.momentum = .changed
        event.time = 0.2
        #expect(view.handleWheelEvent(event) == startsOnPaper)
        event.momentum = .ended
        event.time = 0.3
        #expect(view.handleWheelEvent(event) == startsOnPaper)
        withExtendedLifetime(window) {}
    }

    private func paper(layout: ViewOptions.Layout) throws -> (PaperPDFView, NSWindow) {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("wheel", pages: 8)))
        let rect = NSRect(x: 0, y: 0, width: 420, height: 594)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: true)
        let view = PaperPDFView(frame: rect)
        window.contentView = view
        if view.layer == nil { view.layer = CALayer() }
        view.show(document, at: 0)
        view.apply(ViewOptions(layout: layout, scrollAxis: .horizontal, transition: .cover, showsCoverAlone: false))
        view.shouldReduceMotion = { false }
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
}

/// Synthetic event values keep routing tests independent of attached pointing devices.
nonisolated private final class PaperWheelEvent: NSEvent {
    var target: NSWindow?
    var time: Double = 0
    var travel: CGFloat = -1
    var momentum: NSEvent.Phase = []
    var modifiers: NSEvent.ModifierFlags = []
    var gesture: NSEvent.Phase = []
    var point = NSPoint(x: 100, y: 300)
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var timestamp: TimeInterval { time }
    override var deltaX: CGFloat { 0 }
    override var deltaY: CGFloat { travel }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { travel }
    override var phase: NSEvent.Phase { gesture }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
}
