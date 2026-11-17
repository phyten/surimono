import AppKit
import Testing

@testable import Surimono

@MainActor
struct TrafficLightsTests {
    @Test("帯の部品は信号機の中心の高さへそろって動く")
    func bandLineFollowsTrafficLights() {
        let lights = TrafficLights(centerY: 16, trailingX: 69)
        #expect(TrafficLights.lineOffset(lights, barHeight: 38) == -3)
    }

    @Test("信号機が上のバーの中央にあれば部品は動かない")
    func centeredTrafficLightsLeaveBarAlone() {
        let lights = TrafficLights(centerY: 26, trailingX: 79)
        #expect(TrafficLights.lineOffset(lights, barHeight: 52) == 0)
    }

    @Test("信号機のない窓では部品はバーの中央に残る")
    func noTrafficLightsKeepsMiddle() {
        #expect(TrafficLights.lineOffset(nil, barHeight: 38) == 0)
    }

    @Test("上のバーの最初の部品は緑のボタンの 14pt 右から始まる")
    func titleStartsAfterGap() {
        #expect(TrafficLights(centerY: 16, trailingX: 69).titleLeading == 83)
        #expect(TrafficLights(centerY: 26, trailingX: 79).titleLeading == 93)
    }

    @Test("表示モードの帯は信号機が右へずれた分だけ題の前の場所を広げる")
    func bandRoomFollowsTrafficLights() {
        let narrow = OverlayBand.fixedWidth(lights: TrafficLights(centerY: 16, trailingX: 69))
        let wide = OverlayBand.fixedWidth(lights: TrafficLights(centerY: 26, trailingX: 79))
        #expect(wide - narrow == 10)
    }

    @Test("表示モードの窓では信号機を窓のタイトルバーから読み、帯の高さの中に収まる")
    func readsTrafficLightsOfViewerWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        ViewerWindow.configure(window)
        let lights = try #require(TrafficLights(window: window))
        #expect(lights.centerY > 0 && lights.centerY < ViewerWindow.bandHeight)
        #expect(lights.trailingX > 40 && lights.trailingX < 120)
    }

    @Test("上の帯の高さは信号機の中心の 2 倍で、帯の部品は帯の真ん中と信号機の線に同時に乗る")
    func titleBandIsTwiceTheLightsCenter() {
        #expect(ViewerWindow.titleBandHeight(lightsCenter: 16) == 32)
        #expect(TrafficLights.lineOffset(TrafficLights(centerY: 16, trailingX: 69), barHeight: 32) == 0)
    }

    @Test("タイトルバーの低い macOS でも上の帯は 30pt より低くしない")
    func titleBandHasFloor() {
        #expect(ViewerWindow.titleBandHeight(lightsCenter: 14) == 30)
    }

    @Test("信号機のない窓では上の帯は下の帯と同じ 38pt")
    func titleBandWithoutLightsKeepsPlainHeight() {
        #expect(ViewerWindow.titleBandHeight(lightsCenter: nil) == 38)
    }

    @Test("上の帯の高さは表示モードの窓の信号機の中心の 2 倍に合う")
    func titleBandMatchesViewerWindow() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        ViewerWindow.configure(window)
        let lights = try #require(TrafficLights(window: window))
        #expect(ViewerWindow.titleBandHeight == max(30, (2 * lights.centerY).rounded()))
    }

    @Test("信号機のない窓（フルスクリーンでシステムが別に出すときなど）からは読まない")
    func borderlessWindowHasNoTrafficLights() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.borderless], backing: .buffered,
            defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        #expect(TrafficLights(window: window) == nil)
    }
}
