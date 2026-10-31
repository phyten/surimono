import SurimonoCore
import Testing

struct WheelSequenceTests {
    @Test("パネルで始めた操作の慣性は紙へ移っても取り込まない")
    func overlayMomentum() {
        var sequence = WheelSequence()
        #expect(!sequence.update(phase: .began, timestamp: 0, startsOnPaper: false).owns)
        #expect(!sequence.update(phase: .ended, timestamp: 0.1, startsOnPaper: false).owns)
        #expect(!sequence.update(phase: .momentum, timestamp: 0.2, startsOnPaper: true).owns)
        #expect(!sequence.update(phase: .momentumEnded, timestamp: 0.3, startsOnPaper: true).owns)
    }

    @Test("紙で始めた操作はパネルへ移っても慣性の終わりまで紙が受け持つ")
    func paperMomentum() {
        var sequence = WheelSequence()
        #expect(sequence.update(phase: .began, timestamp: 0, startsOnPaper: true).owns)
        #expect(sequence.update(phase: .changed, timestamp: 0.1, startsOnPaper: false).owns)
        #expect(sequence.update(phase: .ended, timestamp: 0.2, startsOnPaper: false).owns)
        #expect(sequence.update(phase: .momentum, timestamp: 1, startsOnPaper: false).owns)
        #expect(sequence.update(phase: .momentumEnded, timestamp: 2, startsOnPaper: false).owns)
        #expect(!sequence.update(phase: .momentum, timestamp: 3, startsOnPaper: true).owns)
    }

    @Test("開始を見ていない慣性は紙上でも取り込まない")
    func unknownMomentum() {
        var sequence = WheelSequence()
        #expect(!sequence.update(phase: .ended, timestamp: 0, startsOnPaper: true).owns)
        #expect(!sequence.update(phase: .momentum, timestamp: 0.1, startsOnPaper: true).owns)
    }

    @Test("開始通知がない操作は最初の移動位置で受け持ちを決める")
    func firstChanged() {
        var sequence = WheelSequence()
        #expect(!sequence.update(phase: .changed, timestamp: 0, startsOnPaper: false).owns)
        #expect(!sequence.update(phase: .changed, timestamp: 0.1, startsOnPaper: true).owns)
        _ = sequence.update(phase: .ended, timestamp: 0.2, startsOnPaper: true)
        #expect(sequence.update(phase: .changed, timestamp: 1, startsOnPaper: true).owns)
    }

    @Test("マウスの連続入力は開始位置を保ち休止後に決め直す")
    func discrete() {
        var sequence = WheelSequence()
        #expect(!sequence.update(phase: .discrete, timestamp: 0, startsOnPaper: false).owns)
        #expect(!sequence.update(phase: .discrete, timestamp: 0.1, startsOnPaper: true).owns)
        #expect(sequence.update(phase: .discrete, timestamp: 0.6, startsOnPaper: true).owns)
    }

    @Test("紙で送った後にパネルで新しい操作が始まると前の送信済み状態を解除する")
    func newGestureClearsLatch() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 80, phase: .began, timestamp: 0, sensitivity: .normal) == true)
        #expect(turner.update(delta: 0, phase: .ended, timestamp: 0.1, sensitivity: .normal) == nil)
        // The monitor observes the new begin even when another view owns it.
        turner.beginSequence()
        #expect(turner.update(delta: 80, phase: .changed, timestamp: 1, sensitivity: .normal) == true)
    }

    @Test("パネルの新しい操作を渡した後も次の紙の操作では送れる")
    func turnAfterForeignGesture() {
        var sequence = WheelSequence()
        var turner = WheelPageTurner()
        func send(_ phase: WheelPageTurner.Phase, _ time: Double, _ paper: Bool) -> Bool? {
            let decision = sequence.update(phase: phase, timestamp: time, startsOnPaper: paper)
            if decision.startsSequence { turner.beginSequence() }
            guard decision.owns else { return nil }
            return turner.update(delta: 80, phase: phase, timestamp: time, sensitivity: .normal)
        }
        #expect(send(.began, 0, true) == true)
        #expect(send(.ended, 0.1, true) == nil)
        #expect(send(.began, 1, false) == nil)
        #expect(send(.changed, 1.1, true) == nil)
        #expect(send(.ended, 1.2, true) == nil)
        #expect(send(.began, 2, true) == true)
    }
}
