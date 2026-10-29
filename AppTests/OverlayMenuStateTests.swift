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
}
