import AppKit
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct OverlayMenuStateTests {
    @Test("上端38ptに入ると待たずに帯全体を表示する")
    func topEdgeShowsFullBand() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 39))
        #expect(menu.stage == .hidden)
        menu.pointerMoved(to: CGPoint(x: 200, y: 38))
        #expect(menu.stage == .full)
    }

    @Test("帯が場所を取って紙の端が下がっても、止まったポインタは帯の範囲に入ったまま")
    func roomKeepsStillPointerInside() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 30))
        #expect(menu.stage == .full)
        // The window grew 38pt upward around the paper: the same place on the screen is 38pt lower in the content.
        menu.topRoom = 38
        menu.pointerMoved(to: CGPoint(x: 200, y: 68))
        #expect(menu.isPointerOverBand)
        menu.pointerMoved(to: CGPoint(x: 200, y: 77))
        #expect(!menu.isPointerOverBand)
    }

    @Test("帯を隠して場所を返しても、離れたポインタは紙の端の範囲に戻らない")
    func releasingRoomDoesNotReveal() {
        let menu = OverlayMenuState()
        menu.contentHeight = 800
        menu.hasBottomBand = true
        menu.topRoom = 38
        menu.bottomRoom = 38
        // Just beyond both zones while the bands have their room...
        for y: CGFloat in [77, 800 - 38 - 38 - 1] {
            menu.pointerMoved(to: CGPoint(x: 200, y: y))
            #expect(!menu.isPointerOverBand)
        }
        // ...is just beyond the paper's edges once the room is given back.
        menu.topRoom = 0
        menu.bottomRoom = 0
        menu.contentHeight = 724
        for y: CGFloat in [77 - 38, 800 - 38 - 38 - 1 - 38] {
            menu.pointerMoved(to: CGPoint(x: 200, y: y))
            #expect(!menu.isPointerOverBand)
        }
    }

    @Test("ポインタは画面の位置から窓の中の左上基準の位置にし、窓の外やほかの窓の下では持たない")
    func trackerConvertsScreenPoints() {
        let content = NSRect(x: 100, y: 200, width: 600, height: 800)
        let inside = PointerTracker.TrackerView.contentPoint(of: NSPoint(x: 150, y: 990), in: content) { _ in true }
        #expect(inside == CGPoint(x: 50, y: 10))
        #expect(PointerTracker.TrackerView.contentPoint(of: NSPoint(x: 50, y: 990), in: content) { _ in true } == nil)
        #expect(PointerTracker.TrackerView.contentPoint(of: NSPoint(x: 150, y: 990), in: content) { _ in false } == nil)
    }

    @Test("上と下に分けると下の帯の場所でも全体を表示する")
    func bottomZoneShowsBands() {
        let menu = OverlayMenuState()
        menu.hasBottomBand = true
        menu.contentHeight = 800
        menu.pointerMoved(to: CGPoint(x: 200, y: 761))
        #expect(menu.stage == .hidden)
        menu.pointerMoved(to: CGPoint(x: 200, y: 762))
        #expect(menu.stage == .full)
    }

    @Test("上だけのときは窓の下端に乗せても帯を出さない")
    func noBottomZoneWithoutBottomBand() {
        let menu = OverlayMenuState()
        menu.contentHeight = 800
        menu.pointerMoved(to: CGPoint(x: 200, y: 790))
        #expect(menu.stage == .hidden)
    }

    @Test("帯から本文へ離れると1秒後に隠れ、本文で動いても延長しない", .timeLimit(.minutes(1)))
    func leavingBandStartsOneTimer() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        menu.pointerMoved(to: CGPoint(x: 200, y: 100))
        try await Task.sleep(for: .milliseconds(700))
        #expect(menu.stage == .full)
        menu.pointerMoved(to: CGPoint(x: 300, y: 300))
        try await Task.sleep(for: .milliseconds(500))
        #expect(menu.stage == .hidden)
    }

    @Test("窓の外へ離れて1秒後に隠れる", .timeLimit(.minutes(1)))
    func hidesAfterLeavingWindow() async throws {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.pointerExited()
        try await Task.sleep(for: .milliseconds(700))
        #expect(menu.stage == .full)
        try await Task.sleep(for: .milliseconds(500))
        #expect(menu.stage == .hidden)
    }

    @Test("帯へ戻ると非表示の予約を取り消す", .timeLimit(.minutes(1)))
    func returningCancelsHide() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        menu.pointerExited()
        try await Task.sleep(for: .milliseconds(600))
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        try await Task.sleep(for: .milliseconds(600))
        #expect(menu.stage == .full)
    }

    @Test("キーボードで表示した帯は静止しても隠れない", .timeLimit(.minutes(1)))
    func keyboardHasNoIdleTimeout() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 400))
        menu.toggle()
        try await Task.sleep(for: .milliseconds(2800))
        #expect(menu.stage == .full)
        menu.toggle()
        #expect(menu.stage == .hidden)
    }

    @Test("ページ送りでは帯の上にポインタがある間は隠さない")
    func pageTurnRespectsPointer() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        menu.pageTurned()
        #expect(menu.stage == .full)
        menu.pointerMoved(to: CGPoint(x: 200, y: 100))
        menu.pageTurned()
        #expect(menu.stage == .hidden)
    }

    @Test("ポップオーバーを閉じてから1秒待って隠す", .timeLimit(.minutes(1)))
    func popoverHoldsUntilClosed() async throws {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.isHolding = true
        menu.pointerExited()
        menu.pageTurned()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(menu.stage == .full)
        menu.isHolding = false
        #expect(menu.stage == .full)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(menu.stage == .hidden)
    }

    @Test("メニューを開いている間は隠れず閉じてから1秒待つ", .timeLimit(.minutes(1)))
    func trackingHoldsUntilClosed() async throws {
        let menu = OverlayMenuState()
        let popup = NSMenu()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: popup)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: popup) }
        menu.pointerMoved(to: CGPoint(x: 200, y: 200))
        menu.pageTurned()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(menu.stage == .full)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: popup)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(menu.stage == .hidden)
    }

    @Test("Escで隠した帯は動かさなければ再表示せず、固定中はEscで隠れない", .timeLimit(.minutes(1)))
    func escapeAndPin() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        #expect(!menu.hideForEscape(alwaysVisible: true))
        #expect(menu.stage == .full)
        #expect(menu.hideForEscape(alwaysVisible: false))
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.stage == .hidden)
    }
}
