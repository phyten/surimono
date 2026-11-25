import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PageNavigationWindowTests {
    @MainActor private final class Fixture {
        let defaults = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model: DocumentViewModel
        let controller: MemoryDocumentWindowController
        let window: NSWindow

        init() throws {
            let preferences = AppPreferences(defaults: defaults.defaults)
            preferences.menuArrangement = .split
            model = DocumentViewModel(
                data: TestFixtures.pdf("Pages", pages: 8), fileURL: nil, format: .pdf, preferences: preferences,
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            controller = MemoryDocumentWindowController(model: model) {}
            let documentWindow = controller.window
            window = try #require(documentWindow)
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            controller.close()
            defaults.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        func track(rtl: Bool = false) async throws -> ScrubPointer.Input {
            try await wait { self.model.isUpToDate && self.model.pageCount == 8 }
            model.updateViewOptions {
                $0.layout = .single
                $0.transition = .instant
                $0.direction = rtl ? .rightToLeft : .leftToRight
            }
            window.setContentSize(CGSize(width: 1180, height: 720))
            model.isBandAlwaysVisible = true
            let content = try #require(window.contentView)
            var target: ScrubPointer.Input?
            try await wait {
                content.layoutSubtreeIfNeeded()
                let frame = self.model.scrubber.frame
                let y = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
                let center = content.convert(CGPoint(x: frame.midX, y: y), to: content.superview)
                target = content.hitTest(center) as? ScrubPointer.Input
                return frame.width >= BandLayout.scrubberMinimum && target != nil
            }
            return try #require(target)
        }

        /// A real mouse event handed to the view that the window's hit test found under the track (`track()`).
        /// AppKit sends dragged and up to the view that took down; going through the window instead would depend on
        /// the test host being the active app, because an inactive window keeps its first click for itself.
        func pointer(_ type: NSEvent.EventType, at fraction: CGFloat, in track: NSView) throws {
            let p = track.convert(CGPoint(x: fraction * track.bounds.width, y: track.bounds.midY), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: track.mouseDown(with: event)
            case .leftMouseDragged: track.mouseDragged(with: event)
            case .leftMouseUp: track.mouseUp(with: event)
            default: Issue.record("Unexpected event type \(type)")
            }
        }

        func key(_ code: UInt16, _ text: String) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: code == 53 ? [] : [.function, .numericPad],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code))
        }

        func dispatcher() -> ShortcutDispatcher {
            ShortcutDispatcher(controller: .shared, keyWindow: { self.window }, model: { self.model })
        }
    }

    private static func wait(
        _ ready: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !ready(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ready(), sourceLocation: sourceLocation)
    }

    @Test("印刷画面から戻ると、手前の窓を変えずに新しい紙がキー入力を受け取る", arguments: [false, true])
    func focusAfterTray(background: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = fixture.model
        let window = fixture.window
        try await Self.wait { model.isUpToDate && model.paper.view?.window === window }
        model.enterPrintMode()
        try await Self.wait { model.mode == .print && model.hasCurrentPrintPreview && model.paper.view?.window == nil }
        let other = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 240, height: 180),
            styleMask: [.titled], backing: .buffered, defer: true)
        defer { other.orderOut(nil) }
        if background {
            other.makeKeyAndOrderFront(nil)
            try #require(!window.isKeyWindow)
        }
        model.exitPrintMode()
        try await Self.wait {
            model.mode == .view && model.paper.view?.window === window
                && !ViewerWindow.isResizingProgrammatically(window)
        }
        let paper = try #require(model.paper.view)
        // Attaching the paper schedules its responder request on the main actor.
        try await Self.wait {
            let responder = window.firstResponder as? NSView
            return responder === paper || responder?.isDescendant(of: paper) == true
        }
        if background { #expect(!window.isKeyWindow) }
    }

    @Test("入力欄からスクラバーを押すと編集を離れ、Escと解放でページも履歴も変わらない")
    func fieldThenEscape() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let track = try await fixture.track()
        let model = fixture.model
        let field = NSTextField(frame: NSRect(x: 8, y: 80, width: 140, height: 24))
        fixture.window.contentView?.addSubview(field)
        try #require(fixture.window.makeFirstResponder(field))
        try #require((fixture.window.firstResponder as? NSTextView)?.isEditable == true)
        let dispatcher = fixture.dispatcher()
        let escape = try fixture.key(53, "\u{1b}")
        #expect(!dispatcher.handle(escape))
        #expect(!dispatcher.handle(try fixture.key(124, "\u{f703}")))
        let history = model.pageHistory
        let page = model.logicalReadingPage
        try fixture.pointer(.leftMouseDown, at: 0.25, in: track)
        try fixture.pointer(.leftMouseDragged, at: 0.75, in: track)
        try #require(model.scrubber.dragging)
        #expect(dispatcher.handle(escape))
        try fixture.pointer(.leftMouseUp, at: 0.75, in: track)
        #expect(!model.scrubber.dragging && model.logicalReadingPage == page && model.pageHistory == history)
        try await Self.wait { field.currentEditor() == nil }
        // A click does not take keyboard focus, as with a slider: no focus ring after using the mouse.
        #expect(!model.scrubber.keyboardFocus)
        // The paper takes the keys, and the next arrow turns one page through it.
        #expect(ShortcutSurfaceKeys.owner(of: fixture.window.firstResponder) is PaperPDFView)
        let arrow = try fixture.key(124, "\u{f703}")
        if !dispatcher.handle(arrow) { fixture.window.sendEvent(arrow) }
        try await Self.wait { model.logicalReadingPage == page + 1 }
        try #require(fixture.window.makeFirstResponder(field))
        #expect(!dispatcher.handle(escape))
    }

    @Test("押してドラッグしても移動せず、解放で一度だけ履歴を積み、窓を離れた場合は取り消す", arguments: [true, false])
    func pointerCommit(losesKey: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let target = try await fixture.track()
        let model = fixture.model
        try fixture.pointer(.leftMouseDown, at: 0.25, in: target)
        try #require(model.scrubber.dragging && model.logicalReadingPage == 0 && !model.pageHistory.canGoBack)
        try fixture.pointer(.leftMouseDragged, at: 0.99, in: target)
        #expect(model.logicalReadingPage == 0 && !model.pageHistory.canGoBack)
        if losesKey {
            // What AppKit posts when another window becomes key; the test host need not be the active app.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
            try await Self.wait { !model.scrubber.dragging }
        }
        try fixture.pointer(.leftMouseUp, at: 0.99, in: target)
        #expect(model.logicalReadingPage == (losesKey ? 0 : 7))
        #expect(model.pageHistory.canGoBack == !losesKey)
        if !losesKey {
            model.goBack()
            #expect(model.logicalReadingPage == 0 && !model.pageHistory.canGoBack)
        }
    }

    @Test("左右とHomeとEndは紙へ渡らず、左右だけが文書の読み方向に従う", arguments: [true, false])
    func directionalKeys(rtl: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let track = try await fixture.track(rtl: rtl)
        let model = fixture.model
        let dispatcher = fixture.dispatcher()
        model.paper.focus()
        let paper = try #require(ShortcutSurfaceKeys.owner(of: fixture.window.firstResponder) as? PaperPDFView)
        try fixture.pointer(.leftMouseDown, at: 0.5, in: track)
        try fixture.pointer(.leftMouseUp, at: 0.5, in: track)
        // Keyboard navigation gives the track its focus; PDFKit keeps the native responder meanwhile.
        model.scrubber.keyboardFocus = true
        paper.nativeKeyHandler = { _ in Issue.record("PDFKit received a scrubber key") }
        paper.onTurn = { Issue.record("The paper also turned a page") }
        let start = model.logicalReadingPage
        for (code, text, page) in [
            (UInt16(123), "\u{f702}", start + (rtl ? 1 : -1)), (124, "\u{f703}", start),
            (115, "\u{f729}", 0), (119, "\u{f72b}", 7),
        ] {
            let event = try fixture.key(code, text)
            let consumed = dispatcher.handle(event)
            if !consumed { fixture.window.sendEvent(event) }
            #expect(consumed)
            #expect(model.logicalReadingPage == page)
        }
    }

    #if DEBUG
        @Test(
            "見開きのページ一覧は表紙を一枚で置き、組を紙面と同じ左右に並べる（画面の言語の向きによらない）",
            arguments: [(false, false), (true, false), (false, true), (true, true)])
        func spreadRows(rightToLeft: Bool, interfaceRightToLeft: Bool) async throws {
            let fixture = try Fixture()
            defer { fixture.close() }
            _ = try await fixture.track(rtl: rightToLeft)
            fixture.model.updateViewOptions {
                $0.layout = .spread
                $0.showsCoverAlone = true
            }
            var frames: [Int: CGRect] = [:]
            let drawer = ContentsPages(model: fixture.model, popover: false)
                .environment(\.layoutDirection, interfaceRightToLeft ? .rightToLeft : .leftToRight)
                .onPreferenceChange(PageTileFramePreference.self) { value in
                    MainActor.assumeIsolated { frames = value }
                }
            let host = NSHostingView(rootView: drawer)
            host.frame = NSRect(x: 10, y: 50, width: 300, height: 600)
            fixture.window.contentView?.addSubview(host)
            try await Self.wait { frames[0] != nil && frames[1] != nil && frames[2] != nil && frames[3] != nil }
            let cover = try #require(frames[0])
            let (left, right) = try (#require(frames[1]), #require(frames[2]))
            let (nextLeft, nextRight) = try (#require(frames[3]), #require(frames[4]))
            // The cover is alone on its row, in the half where the first page of the paper stands.
            #expect(cover.maxY <= min(left.minY, right.minY) + 1)
            let middle = host.convert(host.bounds, to: nil).midX
            #expect(rightToLeft ? cover.midX < middle : cover.midX > middle)
            // Pages 2 and 3 share a row, in the paper's order.
            #expect(abs(left.midY - right.midY) <= 1 && abs(nextLeft.midY - nextRight.midY) <= 1)
            #expect(rightToLeft ? left.midX > right.midX : left.midX < right.midX)
            #expect(left.maxY <= nextLeft.minY + 1)
        }

        @Test("見開きのページ一覧は表示中の二枚に枠を付け、単ページでは一枚に戻る")
        func selectedTiles() async throws {
            let fixture = try Fixture()
            defer { fixture.close() }
            _ = try await fixture.track()
            fixture.model.updateViewOptions {
                $0.layout = .spread
                $0.showsCoverAlone = false
            }
            var rings = Set<Int>()
            var currents = Set<Int>()
            let drawer = ContentsPages(model: fixture.model, popover: false)
                .onPreferenceChange(PageFocusRingPreference.self) { value in
                    MainActor.assumeIsolated { rings = value }
                }
                .onPreferenceChange(PageCurrentFramePreference.self) { value in
                    MainActor.assumeIsolated { currents = value }
                }
            let host = NSHostingView(rootView: drawer)
            host.frame = NSRect(x: 10, y: 50, width: 300, height: 600)
            fixture.window.contentView?.addSubview(host)
            // Both pages of the spread on screen carry the current frame (and with it the selected trait); framing
            // only `page == current` would leave one.
            try await Self.wait { currents == [0, 1] }
            // Without keyboard focus there is no dashed ring. (A hosted test cannot hand SwiftUI's focus to the
            // drawer, so the ring moving alone is checked by hand.)
            #expect(rings.isEmpty)
            fixture.model.updateViewOptions { $0.layout = .single }
            try await Self.wait { currents == [0] }
        }
    #endif
}
