import AppKit
import SwiftUI

/// The print mode's colors (washi, sumi, shu and ai in light; a deep indigo night in dark). They follow the window's
/// appearance; the paper itself stays white in both.
enum PrintPalette {
    static let chrome = dynamic(light: 0xF3F1EB, dark: 0x18202A)
    static let stage = Color(nsColor: stageColor)
    static let stageColor = dynamicColor(light: 0xE6E2D9, dark: 0x0F151C)
    static let raised = dynamic(light: 0xFBFAF7, dark: 0x1E2732)
    static let hover = dynamic(light: 0x26272B, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let press = dynamic(light: 0x26272B, lightAlpha: 0.1, dark: 0xFFFFFF, darkAlpha: 0.1)
    static let ink = dynamic(light: 0x26272B, dark: 0xE9E7E1)
    static let ink2 = dynamic(light: 0x57585D, dark: 0xB0B6BE)
    static let ink3 = dynamic(light: 0x6A6A6A, dark: 0x8F96A0)
    static let line = dynamic(light: 0x26272B, lightAlpha: 0.11, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let line2 = dynamic(light: 0x26272B, lightAlpha: 0.19, dark: 0xFFFFFF, darkAlpha: 0.15)
    static let line3 = dynamic(light: 0x26272B, lightAlpha: 0.32, dark: 0xFFFFFF, darkAlpha: 0.26)
    static let ai = dynamic(light: 0x2B4C6F, dark: 0x92B3D9)
    static let aiTint = dynamic(light: 0x2B4C6F, lightAlpha: 0.09, dark: 0x92B3D9, darkAlpha: 0.11)
    static let aiTint2 = dynamic(light: 0x2B4C6F, lightAlpha: 0.15, dark: 0x92B3D9, darkAlpha: 0.19)
    static let foldMark = dynamic(light: 0x2B4C6F, lightAlpha: 0.55, dark: 0x92B3D9, darkAlpha: 0.55)
    static let pictogramPaper = dynamic(light: 0xFFFFFF, dark: 0xF4F2EC)
    static let paperRing = dynamic(light: 0x3C301E, lightAlpha: 0.12, dark: 0x000000, darkAlpha: 0.45)
    static let paperShadow = dynamic(light: 0x3C301E, lightAlpha: 0.2, dark: 0x000000, darkAlpha: 0.55)
    static let popShadow = dynamic(light: 0x28200F, lightAlpha: 0.22, dark: 0x000000, darkAlpha: 0.5)
    static let toast = dynamic(light: 0x2A2B2F, dark: 0x2C3744)
    static let toastInk = dynamic(light: 0xF5F3EE, dark: 0xF2F0EA)

    // Vermilion is reserved for the Print button, in both appearances.
    static let shu = fixed(0xC8452D)
    static let shuHover = fixed(0xB93E28)
    static let shuPress = fixed(0xA63622)
    static let shuShadow = Color(.sRGB, red: 120 / 255, green: 32 / 255, blue: 12 / 255, opacity: 0.4)

    // Drawn on the white paper, so they do not change with the appearance.
    static let paper = Color.white
    static let blankPaper = fixed(0xEBEBE8)
    static let blankInk = fixed(0xA2A29E)
    static let foldLine = Color(.sRGB, red: 43 / 255, green: 76 / 255, blue: 111 / 255, opacity: 0.55)

    private static func fixed(_ hex: UInt32) -> Color {
        Color(.sRGB, red: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), opacity: 1)
    }

    private nonisolated static func component(_ hex: UInt32, _ shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }

    private nonisolated static func dynamic(
        light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: dynamicColor(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }

    /// AppKit may resolve a dynamic color while drawing on any thread, so the provider must not be main-actor bound.
    nonisolated static func dynamicColor(
        light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: component(hex, 16), green: component(hex, 8), blue: component(hex, 0),
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}
