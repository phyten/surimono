import AppKit
import SwiftUI

extension View {
    /// The background of what floats over the paper. The paper stays white in the dark appearance, where a material
    /// alone turns mid-grey and washes out secondary text, so a tint of the panel colour goes over the blur.
    func paperOverlayBackground(cornerRadius: CGFloat, tintOpacity: Double = 0.84) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: cornerRadius).fill(PaperOverlayTint.color.opacity(tintOpacity))
            }
        }
    }
}

private enum PaperOverlayTint {
    static let color = Color(nsColor: dynamicColor())

    /// AppKit may resolve a dynamic colour while drawing on any thread, so the provider must not be main-actor bound.
    private nonisolated static func dynamicColor() -> NSColor {
        NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 42 / 255, green: 42 / 255, blue: 44 / 255, alpha: 1)
                : NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1)
        }
    }
}
