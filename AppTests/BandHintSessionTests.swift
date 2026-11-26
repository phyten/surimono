import AppKit
import Testing

@testable import Surimono

@MainActor
struct BandHintSessionTests {
    private let a = CGPoint(x: 11, y: 11)
    private let b = CGPoint(x: 11, y: 51)

    private func session() -> BandHintSession {
        let session = BandHintSession()
        let content = BandHintContent(name: "Chip", detail: "Description")
        session.update([
            "A": .init(
                rect: CGRect(x: 0, y: 0, width: 22, height: 22), content: content, above: false, showsName: true),
            "B": .init(
                rect: CGRect(x: 0, y: 40, width: 22, height: 22), content: content, above: false, showsName: true),
        ])
        return session
    }

    private func waitForCard(_ id: String, in session: BandHintSession) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while session.visible != id, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.visible == id)
    }

    @Test("Tabで帯を離れると帯の保持が解け、Shift+Tabで同じ部品へ戻ると説明が再表示される")
    func focusRoundTrip() async throws {
        let session = session()
        session.setFocus("A")
        try await waitForCard("A", in: session)
        session.handle(.keyDown, keyCode: 48)
        session.setFocus(nil)
        #expect(session.visible == nil && !session.holdsBand)
        session.handle(.keyDown, keyCode: 48)
        session.setFocus("A")
        try await waitForCard("A", in: session)

        session.handle(.keyDown, keyCode: 53)
        session.setFocus("A")
        try await Task.sleep(for: .milliseconds(550))
        #expect(session.visible == nil)
        session.setFocus(nil)
        #expect(!session.holdsBand)
    }

    @Test("表示中は下のチップに切り替えず、閉じた後は元のカード内でも下のチップの説明が出る", arguments: [false, true])
    func chipUnderDismissedCard(dismissOnCard: Bool) async throws {
        let session = session()
        session.moveInEditor(to: a, dragging: false)
        try await waitForCard("A", in: session)
        session.setFootprint(.init(id: "A", rect: CGRect(x: 0, y: 28, width: 160, height: 50)))
        if dismissOnCard {
            session.moveInEditor(to: b, dragging: false)
            #expect(session.hover == "B" && session.visible == "A")
        }
        session.handle(.keyDown, keyCode: 53)
        #expect(session.visible == nil)
        session.moveInEditor(to: CGPoint(x: b.x + 1, y: b.y), dragging: false)
        try await waitForCard("B", in: session)
    }

    @Test("Pickerがマウスアップを消費しても左ボタンを離した後の移動で押下色が消える")
    func missedMouseUp() {
        let session = session()
        session.updateSegments([.single: CGRect(x: 0, y: 0, width: 22, height: 22)])
        session.move(to: a, pressedMouseButtons: 0)
        session.handle(.leftMouseDown)
        session.move(to: CGPoint(x: a.x + 1, y: a.y), pressedMouseButtons: 1)
        #expect(session.pressedSegment == .single)
        session.move(to: b, pressedMouseButtons: 2)
        #expect(session.pressedSegment == nil)
        session.move(to: a, pressedMouseButtons: 0)
        #expect(session.hoveredSegment == .single && session.pressedSegment == nil)
    }

    @Test("3秒読んだカードから直接隣に移ると60msで開く")
    func neighbourAfterReading() {
        let start = ContinuousClock.now
        var timing = BandHintTiming()
        timing.enter("A", at: start)
        timing.advance(to: start + .milliseconds(450))
        let leave = start + .milliseconds(3450)
        timing.enter("B", at: leave)
        timing.advance(to: leave + .milliseconds(59))
        #expect(timing.visible == nil)
        timing.advance(to: leave + .milliseconds(60))
        #expect(timing.visible == "B")
    }
}
