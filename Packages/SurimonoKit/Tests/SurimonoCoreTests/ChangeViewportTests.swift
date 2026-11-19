import CoreGraphics
import SurimonoCore
import Testing

struct ChangeViewportTests {
    private let size = CGSize(width: 300, height: 400)

    @Test("拡大中は収まる変更を縦中央に置き、横は全文が見える分だけ動かす")
    func centerBlock() {
        let mark = CGRect(x: 250, y: 600, width: 100, height: 40)
        #expect(
            ChangeNavigation.targetViewport(for: mark, size: size, zoomed: true, pinnedBandHeight: 38)
                == CGRect(x: 50, y: 420, width: 300, height: 400))
    }

    @Test("拡大中に入りきらない変更は左端と上端を見せ、上に少し余白を取る")
    func oversizedBlock() {
        let mark = CGRect(x: -70, y: 160, width: 440, height: 500)
        #expect(
            ChangeNavigation.targetViewport(for: mark, size: size, zoomed: true, pinnedBandHeight: 0)
                == CGRect(x: -70, y: 148, width: 300, height: 400))
    }

    @Test("等倍ではページ送りを保ち、固定した帯の高さに足りない余白だけを足す")
    func pinnedMargin() {
        let mark = CGRect(x: 5, y: 10, width: 150, height: 20)
        #expect(
            ChangeNavigation.targetViewport(for: mark, size: size, zoomed: false, pinnedBandHeight: 38)
                == CGRect(x: 0, y: -28, width: 300, height: 400))
        #expect(
            ChangeNavigation.targetViewport(for: mark, size: size, zoomed: false, pinnedBandHeight: 0).origin == .zero)
        #expect(
            ChangeNavigation.targetViewport(
                for: mark.offsetBy(dx: 0, dy: 50), size: size, zoomed: false, pinnedBandHeight: 38
            ).origin == .zero)
    }
}
