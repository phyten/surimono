import SurimonoCore
import Testing

struct WheelPageTurnerTests {
    @Test("標準のホイールは短時間に三目盛り進めて初めて送る")
    func discreteTravel() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.2, sensitivity: .normal) == true)
    }

    @Test("小さな操作は四百ミリ秒の休止で忘れる")
    func idleReset() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.51, sensitivity: .normal) == nil)
    }

    @Test("指の一操作では一度だけ送り、休止と慣性でも追加で送らない")
    func gestureAndMomentum() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 36, phase: .began, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 44, phase: .changed, timestamp: 0.1, sensitivity: .normal) == true)
        #expect(turner.update(delta: 200, phase: .changed, timestamp: 1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 200, phase: .ended, timestamp: 1.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 200, phase: .momentum, timestamp: 2, sensitivity: .normal) == nil)
        #expect(turner.update(delta: -80, phase: .began, timestamp: 3, sensitivity: .normal) == false)
    }

    @Test("指の操作をやり直しても送り間隔を守る")
    func cooldown() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 200, phase: .began, timestamp: 0, sensitivity: .normal) == true)
        #expect(turner.update(delta: 200, phase: .began, timestamp: 0.3, sensitivity: .normal) == nil)
        #expect(turner.update(delta: -200, phase: .began, timestamp: 0.36, sensitivity: .normal) == false)
    }

    @Test("逆方向の操作は前の移動量を引き継がない")
    func reversal() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 2, phase: .discrete, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: -2, phase: .discrete, timestamp: 0.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: -1, phase: .discrete, timestamp: 0.2, sensitivity: .normal) == nil)
        #expect(turner.update(delta: -1, phase: .discrete, timestamp: 0.3, sensitivity: .normal) == false)
    }

    @Test(
        "低感度は四目盛り、高感度は二目盛りで送る",
        arguments: [(WheelPageTurner.Sensitivity.low, 4.0), (.high, 2.0)])
    func levels(sensitivity: WheelPageTurner.Sensitivity, travel: Double) {
        var turner = WheelPageTurner()
        for step in 0..<Int(travel - 1) {
            #expect(
                turner.update(delta: 1, phase: .discrete, timestamp: Double(step) * 0.05, sensitivity: sensitivity)
                    == nil)
        }
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.2, sensitivity: sensitivity) == true)
    }

    @Test("加速したマウスの一目盛りでも送らず、送り直後の入力は蓄積しない")
    func acceleratedWheelAndCooldown() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 100, phase: .discrete, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.2, sensitivity: .normal) == true)
        for time in [0.3, 0.4, 0.5, 0.6, 0.7] {
            #expect(turner.update(delta: 1, phase: .discrete, timestamp: time, sensitivity: .normal) == nil)
        }
        #expect(turner.update(delta: 1, phase: .discrete, timestamp: 0.8, sensitivity: .normal) == true)
    }

    @Test("紙の外を通って戻っても同じ指の操作で二度送らない")
    func leavingPaper() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 80, phase: .began, timestamp: 0, sensitivity: .normal) == true)
        turner.discardTravel()
        #expect(turner.update(delta: 100, phase: .changed, timestamp: 1, sensitivity: .normal) == nil)
    }

    @Test("キャンセルした指の操作量を次の操作に持ち越さない")
    func cancellation() {
        var turner = WheelPageTurner()
        #expect(turner.update(delta: 70, phase: .began, timestamp: 0, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 100, phase: .cancelled, timestamp: 0.1, sensitivity: .normal) == nil)
        #expect(turner.update(delta: 20, phase: .began, timestamp: 0.2, sensitivity: .normal) == nil)
    }
}
