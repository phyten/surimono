import AppKit
import SwiftUI

/// The print mode's colors (washi, sumi, shu and ai in light; a deep indigo night in dark). They follow the window's
/// appearance; the paper itself stays white in both.
enum PrintPalette {
    static var chrome: Color { color(.chrome) }
    static var stage: Color { color(.stage) }
    static var stageColor: NSColor { dynamicColor(.stage) }
    static var raised: Color { color(.raised) }
    static var hover: Color { color(.hover) }
    static var press: Color { color(.press) }
    static var ink: Color { color(.ink) }
    static var ink2: Color { color(.ink2) }
    static var ink3: Color { color(.ink3) }
    static var disabledInk: Color { color(.disabledInk) }
    static var line: Color { color(.line) }
    static var line2: Color { color(.line2) }
    static var line3: Color { color(.line3) }
    static var ai: Color { color(.ai) }
    static var bandPlateFill: Color { color(.bandPlateFill) }
    static var bandSegmentTrack: Color { color(.bandSegmentTrack) }
    static var bandOnInk: Color { color(.bandOnInk) }
    /// The fill of a selected standard control in the reading window. The system draws white text on it, which the
    /// bright night indigo of `ai` cannot carry.
    static var aiControl: Color { color(.aiControl) }
    static var aiTint: Color { color(.aiTint) }
    static var warn: Color { color(.warn) }
    static var warnTint: Color { color(.warnTint) }
    static var aiTint2: Color { color(.aiTint2) }
    static var foldMark: Color { color(.foldMark) }
    static var pictogramPaper: Color { color(.pictogramPaper) }
    static var paperRing: Color { color(.paperRing) }
    static var paperShadow: Color { color(.paperShadow) }
    static var popShadow: Color { color(.popShadow) }
    static var toast: Color { color(.toast) }
    static var toastInk: Color { color(.toastInk) }

    // Vermilion is reserved for the Print button, in both appearances.
    static var shu: Color { color(.shu) }
    static var shuHover: Color { color(.shuHover) }
    static var shuPress: Color { color(.shuPress) }
    static var shuShadow: Color { color(.shuShadow) }

    // Drawn on the white paper, so they do not change with the appearance.
    static let paper = Color.white
    /// The preview floats over white paper in either appearance.
    static let previewEdge = Color(.sRGB, white: 0.55, opacity: 1)
    static var blankPaper: Color { color(.blankPaper) }
    static var blankInk: Color { color(.blankInk) }
    static var foldLine: Color { color(.foldLine) }
    /// The indigo for a mark on the paper itself, such as the frame around a spot: `ai` turns pale at night and would
    /// fade on the white sheet.
    static var paperAi: Color { color(.paperAi) }

    nonisolated enum Swatch: CaseIterable {
        case chrome, stage, raised, hover, press, ink, ink2, ink3, disabledInk
        case line, line2, line3, ai, bandPlateFill, bandSegmentTrack, bandOnInk, aiControl, aiTint, aiTint2, warn,
            warnTint
        case foldMark, pictogramPaper, paperRing, paperShadow, popShadow, toast, toastInk
        case shu, shuHover, shuPress, shuShadow, blankPaper, blankInk, foldLine, paperAi

        func resolved(dark: Bool, increasedContrast: Bool, reduceTransparency: Bool) -> NSColor {
            func rgba(_ hex: Int, alpha: Double = 1, over base: Int? = nil) -> NSColor {
                // Flatten against the surface that normally shows through the wash, keeping its perceived tone.
                let matte = base ?? (dark ? 0x1E2732 : 0xFBFAF7)
                func channel(_ shift: Int) -> Double {
                    let value = Double((hex >> shift) & 255) / 255
                    guard reduceTransparency, alpha < 1 else { return value }
                    let background = Double((matte >> shift) & 255) / 255
                    return value * alpha + background * (1 - alpha)
                }
                return NSColor(
                    srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: reduceTransparency ? 1 : alpha)
            }
            func pair(_ light: Int, _ night: Int, alpha: Double = 1) -> NSColor {
                rgba(dark ? night : light, alpha: alpha)
            }
            switch self {
            case .chrome: return pair(0xF3F1EB, 0x18202A)
            case .stage: return pair(0xE6E2D9, 0x0F151C)
            case .raised: return pair(0xFBFAF7, 0x1E2732)
            case .hover: return pair(0x26272B, 0xFFFFFF, alpha: 0.06)
            case .press: return pair(0x26272B, 0xFFFFFF, alpha: 0.10)
            case .ink: return increasedContrast ? pair(0x17181B, 0xFAF9F6) : pair(0x26272B, 0xE9E7E1)
            case .ink2: return increasedContrast ? pair(0x2D2E33, 0xE6E9EE) : pair(0x4C4D52, 0xBDC3CB)
            case .ink3: return increasedContrast ? pair(0x33383C, 0xDCE2EA) : pair(0x545456, 0xA8AFBA)
            case .disabledInk: return pair(0x686967, 0x969FA9)
            case .line, .line2, .line3:
                if increasedContrast {
                    if self == .line3 { return pair(0x50525A, 0x8C94A0) }
                    return pair(0x64666B, 0x84909B)
                }
                let alpha: Double =
                    switch self {
                    case .line: dark ? 0.08 : 0.11
                    case .line2: dark ? 0.15 : 0.19
                    default: dark ? 0.26 : 0.32
                    }
                return pair(0x26272B, 0xFFFFFF, alpha: alpha)
            case .ai:
                if increasedContrast { return pair(0x173858, 0xC5DFFF) }
                fallthrough
            case .bandPlateFill: return pair(0x2B4C6F, 0x92B3D9)
            case .bandSegmentTrack: return pair(0x26272B, 0xFFFFFF, alpha: dark ? 0.06 : 0.05)
            case .bandOnInk: return increasedContrast ? pair(0x173858, 0xE6F2FF) : pair(0x2B4C6F, 0xDDEDFF)
            case .aiControl: return pair(0x2B4C6F, 0x426FA6)
            case .aiTint: return pair(0x2B4C6F, 0x92B3D9, alpha: dark ? 0.11 : 0.09)
            case .aiTint2: return pair(0x2B4C6F, 0x92B3D9, alpha: dark ? 0.19 : 0.15)
            case .warn: return increasedContrast ? pair(0x493000, 0xFFE2AA) : pair(0x6E4900, 0xE5C07A)
            case .warnTint: return pair(0xA06E00, 0xE5C07A, alpha: 0.12)
            case .foldMark:
                return increasedContrast ? pair(0x2B4C6F, 0x92B3D9) : pair(0x2B4C6F, 0x92B3D9, alpha: 0.55)
            case .pictogramPaper: return pair(0xFFFFFF, 0xF4F2EC)
            case .paperRing:
                if increasedContrast { return rgba(0x747474) }
                return rgba(dark ? 0x000000 : 0x3C301E, alpha: dark ? 0.45 : 0.12, over: 0xFFFFFF)
            case .paperShadow: return pair(0x3C301E, 0x000000, alpha: dark ? 0.55 : 0.20)
            case .popShadow: return pair(0x28200F, 0x000000, alpha: dark ? 0.50 : 0.22)
            case .toast: return pair(0x2A2B2F, 0x2C3744)
            case .toastInk: return pair(0xF5F3EE, 0xF2F0EA)
            case .shu: return rgba(0xC8452D)
            case .shuHover: return rgba(0xB93E28)
            case .shuPress: return rgba(0xA63622)
            case .shuShadow: return rgba(0x78200C, alpha: 0.4)
            case .blankPaper: return rgba(0xEBEBE8)
            case .blankInk: return rgba(0x545450)
            case .foldLine: return rgba(0x2B4C6F, alpha: increasedContrast ? 1 : 0.55, over: 0xFFFFFF)
            case .paperAi: return rgba(0x2B4C6F)
            }
        }
    }

    private static func color(_ swatch: Swatch) -> Color { Color(nsColor: dynamicColor(swatch)) }

    private struct ProviderKey: Hashable {
        let swatch: Swatch
        let increasedContrast: Bool
        let reduceTransparency: Bool
    }

    // Reuse each provider so reading the same role in consecutive layout passes produces the same SwiftUI color.
    private static var providers: [ProviderKey: NSColor] = [:]

    private static func dynamicColor(_ swatch: Swatch) -> NSColor {
        let options = DisplayAccessibility.shared.options
        let key = ProviderKey(
            swatch: swatch, increasedContrast: options.increasedContrast, reduceTransparency: options.reduceTransparency
        )
        if let cached = providers[key] { return cached }
        // AppKit may resolve a color on a drawing thread, after the SwiftUI update that chose these settings.
        let provider = NSColor(name: nil) { @Sendable appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return swatch.resolved(
                dark: dark, increasedContrast: options.increasedContrast, reduceTransparency: options.reduceTransparency
            )
        }
        providers[key] = provider
        return provider
    }
}
