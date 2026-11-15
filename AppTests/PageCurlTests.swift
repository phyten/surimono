import Foundation
import Testing

@testable import Surimono

@MainActor
struct PageCurlTests {
    @Test("左から右へ読む本で次へめくると、右下の角から持ち上がって左へ抜ける")
    func forwardInLeftToRightBook() {
        let curl = PageCurl(forward: true, nextFromRight: true)
        #expect(abs(curl.angle - (-Double.pi + PageCurl.lift)) < 0.000_1)
    }

    @Test("前へ戻るときは、次へめくるのと左右を逆にして、もう一度次へめくったようには見せない")
    func backMirrorsForward() {
        let forward = PageCurl(forward: true, nextFromRight: true)
        let back = PageCurl(forward: false, nextFromRight: true)
        #expect(abs(back.angle - (-PageCurl.lift)) < 0.000_1)
        // Mirrored across the vertical: the same rise from the lower corner, the other way across the page.
        #expect(abs(cos(back.angle) + cos(forward.angle)) < 0.000_1)
        #expect(abs(sin(back.angle) - sin(forward.angle)) < 0.000_1)
    }

    @Test("右から左へ読む本では、次へめくる向きと戻る向きが入れ替わる")
    func rightToLeftBook() {
        #expect(
            PageCurl(forward: true, nextFromRight: false).angle == PageCurl(forward: false, nextFromRight: true).angle)
        #expect(
            PageCurl(forward: false, nextFromRight: false).angle == PageCurl(forward: true, nextFromRight: true).angle)
    }

    @Test("めくりの丸みは紙の短い辺に比例し、小さな紙も大きな紙も同じようにめくれる")
    func radiusFollowsThePaper() {
        let small = PageCurl.radius(for: CGSize(width: 400, height: 560))
        let large = PageCurl.radius(for: CGSize(width: 1200, height: 1680))
        #expect(abs(large / small - 3) < 0.000_1)
        #expect(abs(small - 400 * PageCurl.radiusShare) < 0.000_1)
    }

    @Test("めくりの効果に丸みを渡し、影つきのめくりがあれば紙の裏と影の強さも渡す")
    func filterCarriesTheFeel() throws {
        let filter = try #require(
            PageCurl(forward: true, nextFromRight: true).filter(extent: CGRect(x: 0, y: 0, width: 500, height: 700)))
        #expect(["CIPageCurlWithShadowTransition", "CIPageCurlTransition"].contains(filter.name))
        #expect((filter.value(forKey: "inputRadius") as? Double) == 100)
        // A machine without the shadowed filter falls back to the plain one, which has no shadow to ask about.
        let keys = Set(filter.inputKeys)
        if keys.contains("inputShadowAmount") {
            #expect((filter.value(forKey: "inputShadowAmount") as? Double) == PageCurl.shadowAmount)
        }
        if keys.contains("inputBacksideImage") {
            #expect(filter.value(forKey: "inputBacksideImage") != nil)
        }
    }
}
