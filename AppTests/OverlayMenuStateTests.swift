import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Surimono

@MainActor
struct OverlayMenuStateTests {
    @Test("乗せると段階1になり、上部に留まると段階2になる", .timeLimit(.minutes(1)))
    func stages() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 400))
        #expect(menu.stage == .hidden)
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.stage == .compact)
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        try await Task.sleep(for: .milliseconds(400))
        #expect(menu.stage == .full)
    }

    @Test("離れてもすぐには隠れず、少し待つと隠れる", .timeLimit(.minutes(1)))
    func hidesAfterLeaving() async throws {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.pointerExited()
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.stage == .full)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(menu.stage == .hidden)
    }

    @Test("ページを送るとすぐに隠れる")
    func pageTurnHides() {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.pageTurned()
        #expect(menu.stage == .hidden)
    }

    @Test("ポップオーバーを開いている間は、ページを送っても離れても隠れない", .timeLimit(.minutes(1)))
    func holdingKeepsMenu() async throws {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.isHolding = true
        menu.pageTurned()
        menu.pointerExited()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(menu.stage == .full)
    }

    @Test("キーボードで全部のメニューを出し入れできる")
    func keyboardToggle() {
        let menu = OverlayMenuState()
        menu.toggle()
        #expect(menu.stage == .full)
        menu.toggle()
        #expect(menu.stage == .hidden)
    }

    @Test("段階1が出てから段階2になる前に隠すと、あとから段階2にならない", .timeLimit(.minutes(1)))
    func hidingCancelsPendingFullStage() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        for _ in 0..<60 where menu.stage == .hidden {
            try await Task.sleep(for: .milliseconds(5))
        }
        menu.hideNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(menu.stage == .hidden)
    }

    @Test("ポインタが帯の上にあると、帯を使っている状態になる")
    func pointerInsideBand() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        #expect(menu.isPointerOverBand)
    }

    @Test("ポインタが帯の下へ移ると、帯を使っている状態でなくなる")
    func pointerBelowBand() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        menu.pointerMoved(to: CGPoint(x: 200, y: 60))
        #expect(!menu.isPointerOverBand)
    }

    @Test("ポインタが窓から出ると、帯を使っている状態でなくなる")
    func pointerExitClearsBand() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 20))
        menu.pointerExited()
        #expect(!menu.isPointerOverBand)
    }

    @Test("帯から開いたポップオーバーがある間は、ポインタが帯の外でも帯を使っている状態になる")
    func holdingCountsAsOverBand() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 400))
        menu.isHolding = true
        #expect(menu.isPointerOverBand)
        menu.isHolding = false
        #expect(!menu.isPointerOverBand)
    }

    @Test("帯の中や帯の外で動かすだけでは、帯の状態の変化を知らせない")
    func movesWithinOneRegionDoNotNotify() {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 10))
        let flag = ChangeFlag()
        withObservationTracking {
            _ = menu.isPointerOverBand
        } onChange: {
            flag.fired = true
        }
        menu.pointerMoved(to: CGPoint(x: 260, y: 20))
        #expect(!flag.fired)
        menu.pointerMoved(to: CGPoint(x: 260, y: 80))
        #expect(flag.fired)
        flag.fired = false
        withObservationTracking {
            _ = menu.isPointerOverBand
        } onChange: {
            flag.fired = true
        }
        menu.pointerMoved(to: CGPoint(x: 300, y: 120))
        #expect(!flag.fired)
    }

    @Test("帯から開いたメニューを追っている間は、ポインタが窓の外でも帯を使っている状態になる", .timeLimit(.minutes(1)))
    func menuTrackingKeepsTheBandInUse() async throws {
        let menu = OverlayMenuState()
        menu.pointerMoved(to: CGPoint(x: 200, y: 10))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        // The observers run on the main queue, so let them run.
        try await Task.sleep(for: .milliseconds(50))
        menu.pointerExited()
        #expect(menu.isPointerOverBand)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        try await Task.sleep(for: .milliseconds(50))
        #expect(!menu.isPointerOverBand)
    }
}

/// Observation calls `onChange` synchronously on the thread that mutates the property, here the main actor, so the
/// flag is only touched from one thread.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
