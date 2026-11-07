import SwiftUI

extension View {
    /// The background of what floats over the paper. The paper stays white in the dark appearance, where a material
    /// alone turns mid-grey and washes out secondary text, so a tint of the panel colour goes over the blur.
    func paperOverlayBackground(cornerRadius: CGFloat, tintOpacity: Double = 0.84) -> some View {
        background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: cornerRadius).fill(PrintPalette.raised.opacity(tintOpacity))
            }
        }
    }
}
