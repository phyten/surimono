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
        #expect(!menu.hideForEscape(pinned: true))
        #expect(menu.stage == .full)
        #expect(menu.hideForEscape(pinned: false))
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.stage == .hidden)
    }
}
