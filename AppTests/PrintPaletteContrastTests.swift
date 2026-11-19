import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

struct PrintPaletteContrastTests {
    private typealias Swatch = PrintPalette.Swatch

    /// WCAG measures the final sRGB colors, including the ground that shows through a state wash.
    private func over(_ foreground: NSColor, _ ground: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        func blend(_ component: KeyPath<NSColor, CGFloat>) -> CGFloat {
            foreground[keyPath: component] * alpha + ground[keyPath: component] * (1 - alpha)
        }
        return NSColor(
            srgbRed: blend(\.redComponent), green: blend(\.greenComponent), blue: blend(\.blueComponent), alpha: 1)
    }

    private func hex(_ color: NSColor) -> String {
        String(
            format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    @Test("刷り台の文字と枠は両方の外観と表示設定で背景から読み分けられる", arguments: [false, true], [false, true])
    func paletteContrast(dark: Bool, increased: Bool) throws {
        for reduced in [false, true] {
            func color(_ swatch: Swatch) -> NSColor {
                swatch.resolved(dark: dark, increasedContrast: increased, reduceTransparency: reduced)
            }
            func check(_ ink: NSColor, _ ground: NSColor, _ threshold: Double, _ usage: String) throws {
                let ratio = try #require(CodeColor.contrast(hex(ink), hex(ground)))
                #expect(
                    ratio >= threshold, "\(usage): \(ratio), dark=\(dark), increased=\(increased), reduced=\(reduced)")
            }
            let labels: [(Swatch, Double)] = [
                (.ink, 4.5), (.ink2, increased ? 7 : 4.5), (.ink3, increased ? 7 : 4.5),
                (.ai, 4.5), (.warn, 4.5), (.disabledInk, 3),
            ]
            let surfaces: [Swatch] = [.chrome, .stage, .raised]
            let states: [Swatch?] = [nil, .hover, .press, .aiTint, .aiTint2, .warnTint]
            for surface in surfaces {
                for state in states {
                    let ground = state.map { over(color($0), color(surface)) } ?? color(surface)
                    let usage = "\(surface)/\(String(describing: state))"
                    for (ink, threshold) in labels { try check(color(ink), ground, threshold, "\(ink) on \(usage)") }
                    if increased {
                        for line in [Swatch.line, .line2, .line3] {
                            try check(color(line), ground, 3, "\(line) on \(usage)")
                        }
                    }
                }
            }
            let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            for fill in [Swatch.shu, .shuHover, .shuPress, .aiControl] {
                try check(white, color(fill), 4.5, "white on \(fill)")
            }
            for (ink, fill) in [(Swatch.raised, Swatch.ai), (.blankInk, .blankPaper), (.toastInk, .toast)] {
                try check(color(ink), color(fill), 4.5, "\(ink) on \(fill)")
            }
            let options = DisplayAccessibility.Options(increasedContrast: increased, reduceTransparency: reduced)
            for opacity in [0.2, 0.28] {
                let action = options.fill(.white, opacity: opacity, over: Color(nsColor: color(.toast)))
                let background = try #require(NSColor(action).usingColorSpace(.sRGB))
                try check(white, over(background, color(.toast)), 4.5, "toast action")
            }
            try check(color(.paperAi), white, 4.5, "paper indigo on white")
            if increased {
                for line in [Swatch.paperRing, .line2, .line3, .foldLine] {
                    try check(color(line), white, 3, "\(line) on white sample")
                }
            }
        }
    }

    @Test("表示設定の通知を受けるたびに二つの設定を個別に読み直す")
    @MainActor func followsChanges() {
        let center = NotificationCenter()
        var current = DisplayAccessibility.Options(increasedContrast: false, reduceTransparency: false)
        let display = DisplayAccessibility(center: center) { current }
        for (increased, reduced) in [(true, false), (true, true), (false, true), (false, false)] {
            current = .init(increasedContrast: increased, reduceTransparency: reduced)
            center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(display.options == current)
        }
    }

    @Test("選択色が明るいときと暗いときで文字の明暗を選び直す")
    func selectedText() {
        let environment = EnvironmentValues()
        #expect(DisplayAccessibility.selectionInk(on: Color.yellow.resolve(in: environment)) == .black)
        #expect(DisplayAccessibility.selectionInk(on: Color.black.resolve(in: environment)) == .white)
    }

    @Test("半透明のパネルは透明度を下げたときだけ完全に不透明になる", arguments: [false, true], [false, true])
    func panelFill(increased: Bool, reduced: Bool) {
        let options = DisplayAccessibility.Options(increasedContrast: increased, reduceTransparency: reduced)
        let ink = Color(.sRGB, red: 0.2, green: 0.3, blue: 0.4)
        let fill = options.fill(ink, opacity: 0.3, over: .white).resolve(in: EnvironmentValues())
        #expect(abs(fill.opacity - (reduced ? 1 : 0.3)) < 0.001)
    }

    @Test("透明度を下げると状態の色は背後の絵を透かさない", arguments: [false, true], [false, true])
    func opaqueSwatches(dark: Bool, increased: Bool) {
        for swatch in Swatch.allCases {
            #expect(
                swatch.resolved(dark: dark, increasedContrast: increased, reduceTransparency: true).alphaComponent == 1)
        }
        let normal = Swatch.hover.resolved(dark: dark, increasedContrast: increased, reduceTransparency: false)
        let raised = Swatch.raised.resolved(dark: dark, increasedContrast: increased, reduceTransparency: false)
        let opaque = Swatch.hover.resolved(dark: dark, increasedContrast: increased, reduceTransparency: true)
        #expect(hex(opaque) == hex(over(normal, raised)))
    }
}
