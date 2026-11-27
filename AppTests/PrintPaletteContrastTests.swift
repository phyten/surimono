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

    @MainActor
    @Test("暗い読み方パネルの固定値は札とパネルの両方で三対一以上になり、有効な値より薄い")
    func lockedReadingValue() throws {
        let locked = try renderedContrast(readingMenu("2 levels", locked: true))
        let enabled = try renderedContrast(readingMenu("2 levels", locked: false))
        let detail = "locked \(locked), enabled \(enabled)"
        #expect(locked.onFill >= 3 && locked.onPanel >= 3, "\(detail)")
        #expect(locked.onFill < enabled.onFill && locked.onPanel < enabled.onPanel, "\(detail)")
    }

    @MainActor
    @Test("暗い札の文字は四つの表示設定で読め、高コントラスト時は枠をパネルから見分けられる", arguments: [false, true], [false, true])
    func lockedBadgeContrast(increased: Bool, reduced: Bool) throws {
        let display = DisplayAccessibility.Options(increasedContrast: increased, reduceTransparency: reduced)
        let sample = try renderedContrast(
            LockedReadingBadge(valueLabel: Text(verbatim: "2 levels"), display: display).disabled(true))
        let detail = "increased=\(increased) reduced=\(reduced) \(sample)"
        #expect(sample.onFill >= 3 && sample.onPanel >= 3, "\(detail)")
        if increased {
            #expect(sample.edgeOnPanel >= 3, "\(detail)")
        } else {
            #expect(sample.edge == sample.fill, "\(detail)")
        }
    }

    @MainActor
    @Test("固定値の札には文字と矢印が収まり、選択欄と高さが揃う", arguments: UILanguage.supported)
    func lockedReadingValueSize(language: String) throws {
        let strings = try #require(
            Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
        for key in ["None", "Show All Except LOGBOOK"] {
            let value = strings.localizedString(forKey: key, value: nil, table: nil)
            let badge = NSHostingView(rootView: readingMenu(value, locked: true)).fittingSize
            let native = NSHostingView(rootView: readingMenu(value, locked: false)).fittingSize
            let title = NSHostingView(rootView: Text(verbatim: value)).fittingSize
            #expect(abs(badge.height - native.height) <= 1, "\(language) \(key): badge=\(badge), native=\(native)")
            // Leading inset, gap, indicator and trailing inset.
            #expect(abs(badge.width - title.width - (12 + 18 + 10 + 8)) <= 1, "\(badge), title=\(title)")
        }
    }

    @MainActor
    @Test("札の自然幅では値が収まり、文字の幅を半分にすると省略されても矢印との間に余白が残る", arguments: UILanguage.supported)
    func lockedReadingValueTruncation(language: String) throws {
        let strings = try #require(
            Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
        for (key, shouldTruncate) in [("None", false), ("Show All Except LOGBOOK", true)] {
            let value = strings.localizedString(forKey: key, value: nil, table: nil)
            let menu = readingMenu(value, locked: true)
            let natural = NSHostingView(rootView: menu).fittingSize.width
            let title = NSHostingView(rootView: Text(verbatim: value)).fittingSize.width
            let width = shouldTruncate ? floor(natural - title / 2) : ceil(natural)
            var truncated: Bool?
            let badge = menu.textRenderer(ObservedTitle { truncated = $0 })
                .frame(maxWidth: width, alignment: .trailing)
            let image = try bitmap(badge)
            #expect(truncated == shouldTruncate, "\(language) \(value) width=\(width) natural=\(natural)")
            // Both samples are relative to the trailing edge, even when the title fits naturally.
            let fill = try image.color(x: image.size.width - 25, y: 2)
            #expect(try image.matches(fill, trailing: 19..<32), "\(value): the gap contains ink")
            #expect(try !image.matches(fill, trailing: 8..<18), "\(value): missing indicator")
        }
    }

    private struct ObservedTitle: TextRenderer {
        let report: (Bool) -> Void
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            report(layout.isTruncated)
            for line in layout { context.draw(line) }
        }
    }

    @MainActor
    private func readingMenu(_ value: String, locked: Bool) -> some View {
        ReadingMenu(label: "Heading Numbers", selection: .constant(0), valueLabel: Text(verbatim: value)) {
            Text(verbatim: value).tag(0)
        }
        .disabled(locked).environment(\.colorScheme, .dark)
    }

    @MainActor
    private func bitmap(_ content: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content.background(PrintPalette.raised).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    @MainActor
    private func renderedContrast(_ content: some View) throws -> (
        ink: String, fill: String, panel: String, edge: String, onFill: Double, onPanel: Double, edgeOnPanel: Double
    ) {
        let image = try bitmap(content.padding(8))
        let panel = hex(try image.color(x: 2, y: 2))
        let fill = hex(try image.color(x: 12, y: image.size.height / 2))
        let edge = hex(try image.color(x: 8, y: image.size.height / 2))
        var ink = fill
        var onFill = 1.0
        // The leading half contains the first glyphs and excludes the trailing indicator.
        for x in Int(16 * image.scaleX)..<image.pixelsWide / 2 {
            for y in Int(13 * image.scaleY)..<image.pixelsHigh - Int(13 * image.scaleY) {
                let color = hex(try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)))
                let ratio = try #require(CodeColor.contrast(color, fill))
                if ratio > onFill { (ink, onFill) = (color, ratio) }
            }
        }
        return (
            ink, fill, panel, edge, onFill, try #require(CodeColor.contrast(ink, panel)),
            try #require(CodeColor.contrast(edge, panel))
        )
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

    @Test("帯の説明カードのオン・オフと無効理由は両方の地色で4.5対1以上になる", arguments: [false, true], [false, true])
    @MainActor func hintContrast(dark: Bool, increased: Bool) throws {
        let colors = BandHintCard.Colors(dark: dark, increasedContrast: increased)
        func rgb(_ color: Color) throws -> NSColor { try #require(NSColor(color).usingColorSpace(.sRGB)) }
        let paper = try rgb(colors.paper)
        let active = try rgb(colors.active)
        let secondary = try rgb(colors.secondary)
        #expect(paper.alphaComponent == 1)
        #expect(hex(paper) == (dark ? "#27313d" : "#fbfaf7"))
        if dark { #expect(hex(active) == "#93c0f0") }
        for ink in [active, secondary] {
            let ratio = try #require(CodeColor.contrast(hex(over(ink, paper)), hex(paper)))
            #expect(ratio >= 4.5)
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

extension NSBitmapImageRep {
    fileprivate var scaleX: CGFloat { CGFloat(pixelsWide) / size.width }
    fileprivate var scaleY: CGFloat { CGFloat(pixelsHigh) / size.height }

    fileprivate func color(x: CGFloat, y: CGFloat) throws -> NSColor {
        try #require(colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.sRGB))
    }

    fileprivate func matches(_ fill: NSColor, trailing: Range<Int>) throws -> Bool {
        let start = Int(ceil((size.width - CGFloat(trailing.upperBound)) * scaleX))
        let end = Int(floor((size.width - CGFloat(trailing.lowerBound)) * scaleX))
        for x in start..<end {
            for y in pixelsHigh / 4..<pixelsHigh * 3 / 4 {
                if try #require(colorAt(x: x, y: y)?.usingColorSpace(.sRGB)) != fill { return false }
            }
        }
        return true
    }
}
