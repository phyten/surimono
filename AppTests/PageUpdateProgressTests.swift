import Testing

@testable import Surimono

struct PageUpdateProgressTests {
    @Test("200 ms で表示が追いつけば何も表示も通知もしない")
    func shortUpdate() {
        let start = ContinuousClock.now
        var progress = PageUpdateProgress()
        #expect(progress.update(.behind, at: start) == nil)
        #expect(progress.display == .hidden)
        #expect(progress.update(.current, at: start + .milliseconds(200)) == nil)
        #expect(progress.display == .hidden)
        #expect(progress.nextDeadline == nil)
    }

    @Test("変更を重ねても最初から 350 ms で表示し、1 秒で一度通知し、5 秒で文言を添える")
    func sustainedUpdate() {
        var progress = PageUpdateProgress()
        let start = ContinuousClock.now
        for elapsed in [0, 300, 349] {
            #expect(progress.update(.behind, at: start + .milliseconds(elapsed)) == nil)
            #expect(progress.display == .hidden)
            #expect(progress.nextDeadline == start + .milliseconds(350))
        }
        #expect(progress.update(.behind, at: start + .milliseconds(350)) == nil)
        #expect(progress.display == .spinner)
        #expect(progress.nextDeadline == start + .seconds(1))
        #expect(progress.update(.behind, at: start + .seconds(1)) == .started)
        #expect(progress.nextDeadline == start + .seconds(5))
        #expect(progress.update(.behind, at: start + .milliseconds(4999)) == nil)
        #expect(progress.display == .spinner)
        #expect(progress.update(.behind, at: start + .seconds(5)) == nil)
        #expect(progress.display == .text)
        #expect(progress.update(.current, at: start + .seconds(6)) == .finished)
        #expect(progress.display == .hidden)
        #expect(progress.update(.current, at: start + .seconds(6)) == nil)
    }

    @Test("表示直後でも完了すればすぐ消え、失敗には完了通知を出さない")
    func stopAndRestart() {
        var progress = PageUpdateProgress()
        let start = ContinuousClock.now
        _ = progress.update(.behind, at: start)
        _ = progress.update(.behind, at: start + .milliseconds(350))
        #expect(progress.update(.current, at: start + .milliseconds(351)) == nil)
        #expect(progress.display == .hidden)
        #expect(progress.update(.behind, at: start + .seconds(2)) == nil)
        #expect(progress.update(.behind, at: start + .seconds(3)) == .started)
        #expect(progress.update(.inactive, at: start + .seconds(4)) == nil)
        #expect(progress.display == .hidden)
    }
}
