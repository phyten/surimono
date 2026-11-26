import CoreGraphics
import Testing

@testable import Surimono

@MainActor
struct SettingsWindowPlacementTests {
    private let first = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let second = CGRect(x: -1920, y: 240, width: 1920, height: 1080)
    private let chrome = CGSize(width: 0, height: 28)

    @Test("キーウインドウの画面を優先し、なければポインタの画面を選ぶ")
    func screenSelection() {
        let screens = [first, second]
        let pointer = CGPoint(x: -40, y: 1319)
        #expect(SettingsWindowPlacement.screen(key: first, screens: screens, pointer: pointer, frame: { $0 }) == first)
        #expect(SettingsWindowPlacement.screen(key: nil, screens: screens, pointer: pointer, frame: { $0 }) == second)
    }

    @Test("同じ画面の現在の操作スペースに表示中のときだけ位置を保つ")
    func keepVisibleWindow() {
        #expect(
            !SettingsWindowPlacement.needsPlacement(
                isVisible: true, isMiniaturized: false, onActiveSpace: true, onTargetScreen: true))
        #expect(
            SettingsWindowPlacement.needsPlacement(
                isVisible: true, isMiniaturized: false, onActiveSpace: false, onTargetScreen: true))
        #expect(
            SettingsWindowPlacement.needsPlacement(
                isVisible: true, isMiniaturized: false, onActiveSpace: true, onTargetScreen: false))
        #expect(
            SettingsWindowPlacement.needsPlacement(
                isVisible: false, isMiniaturized: false, onActiveSpace: true, onTargetScreen: true))
        #expect(
            SettingsWindowPlacement.needsPlacement(
                isVisible: true, isMiniaturized: true, onActiveSpace: true, onTargetScreen: true))
    }

    @Test("既定の内容とタイトルバーを合わせて可視領域の中央に置く")
    func defaultFrame() {
        let visible = CGRect(x: -1900, y: 240, width: 1880, height: 1040)
        #expect(
            SettingsWindowPlacement.frame(in: visible, savedContentSize: nil, chrome: chrome)
                == CGRect(x: -1480, y: 366, width: 1040, height: 788))
    }

    @Test("保存した内容の大きさで現在の画面に中央揃えする")
    func savedFrame() {
        #expect(
            SettingsWindowPlacement.frame(in: first, savedContentSize: CGSize(width: 900, height: 600), chrome: chrome)
                == CGRect(x: 270, y: 136, width: 900, height: 628))
    }

    @Test("大きすぎる保存寸法は可視領域の四辺に12ポイントを残して収める")
    func smallerScreen() {
        let visible = CGRect(x: 90, y: 30, width: 920, height: 680)
        #expect(
            SettingsWindowPlacement.frame(
                in: visible, savedContentSize: CGSize(width: 1500, height: 1200), chrome: chrome)
                == CGRect(x: 102, y: 42, width: 896, height: 656))
    }

    @Test("余白の狭い画面でも既存の最小内容寸法を保つ")
    func minimumSize() {
        let visible = CGRect(x: 0, y: 30, width: 830, height: 580)
        #expect(
            SettingsWindowPlacement.frame(
                in: visible, savedContentSize: CGSize(width: 700, height: 500), chrome: chrome)
                == CGRect(x: 5, y: 36, width: 820, height: 568))
    }
}
