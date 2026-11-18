import SwiftUI

extension View {
    /// The background of what floats over the paper. The paper stays white in the dark appearance, where a material
    /// alone turns mid-grey and washes out secondary text, so a tint of the panel colour goes over the blur.
    func paperOverlayBackground(_ corner: CornerRole?, tintOpacity: Double = 0.84) -> some View {
        let shape = corner.map { AnyShape($0.shape) } ?? AnyShape(Rectangle())
        return background {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(PrintPalette.raised.opacity(tintOpacity))
            }
        }
    }
}
