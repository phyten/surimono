import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct AppCornersTests {
    @Test("角の丸みは標準で始まり選んだ形を次の起動で復元する")
    func roundTrip() {
        let suite = BandTestDefaultsSuite()
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.corners == .standard)
        for preset in [CornerPreset.round, .square, .standard] {
            preferences.corners = preset
            #expect(AppPreferences(defaults: suite.defaults).corners == preset)
        }
    }

    @Test("未知の角の丸みは標準で表示する")
    func unknownValue() {
        let suite = BandTestDefaultsSuite()
        suite.defaults.set("other", forKey: "corners")
        #expect(AppPreferences(defaults: suite.defaults).corners == .standard)
    }

    @Test("標準だけがシステムのコントロールを使う")
    func systemStyles() {
        #expect(CornerPreset.standard.usesSystemControls)
        #expect(!CornerPreset.square.usesSystemControls)
        #expect(!CornerPreset.round.usesSystemControls)
    }

    @Test("丸い設定でもページを囲む枠の半径は6ptまで")
    func spreadFrame() {
        let rect = CGRect(x: 0, y: 0, width: 30, height: 39)
        let frame = AppCornerShape.spreadFrame(preset: .round)
        #expect(frame.path(in: rect) == RoundedRectangle(cornerRadius: 6).path(in: rect))
    }

    @Test("標準の角とカプセルは従来の半径と輪郭を保つ")
    func originalRadii() {
        let radii: [CGFloat] = [1, 2, 3, 3.5, 4, 4.5, 5, 6, 7, 8, 9, 10, 12, 14]
        #expect(radii.count == CornerRole.allCases.count)
        let rect = CGRect(x: 0, y: 0, width: 46, height: 24)
        for (role, radius) in zip(CornerRole.allCases, radii) {
            #expect(CornerPreset.standard.radius(for: role, shortestSide: 24) == radius)
            for inset: CGFloat in [0, 0.5, 1] {
                let current = AppCornerShape(role: role, preset: .standard).inset(by: inset)
                #expect(
                    current.path(in: rect) == RoundedRectangle(cornerRadius: radius).inset(by: inset).path(in: rect))
            }
        }
        for preset in [CornerPreset.standard, .round] {
            #expect(AppCornerShape(role: nil, preset: preset).path(in: rect) == Capsule().path(in: rect))
        }
        #expect(
            AppCornerShape(role: nil, preset: .square).path(in: rect)
                == RoundedRectangle(cornerRadius: 2).path(in: rect))
    }
}
