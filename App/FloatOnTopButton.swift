import SwiftUI

/// The band's switch for keeping the window above other apps: a pushpin, tilted and drawn in outline while the window
/// floats freely, standing upright and filled while it is pinned on top.
struct FloatOnTopButton: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Toggle("Float on Top", isOn: $model.isAlwaysOnTop)
            .toggleStyle(PinToggleStyle())
            .help("Float on Top")
    }
}

private struct PinToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            PinGlyph(isPinned: configuration.isOn)
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(PrintPalette.ink))
                // The whole square takes the click, not only the strokes of the outline.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A pushpin drawn on a 16-point grid with the stroke weight of the band's other symbols.
struct PinGlyph: View {
    let isPinned: Bool
    static let size: CGFloat = 16
    private static let stroke: CGFloat = 1.35

    var body: some View {
        ZStack {
            if isPinned {
                PinHead().fill()
                PinHead().stroke(style: StrokeStyle(lineWidth: Self.stroke, lineJoin: .round))
            } else {
                PinHead().stroke(style: StrokeStyle(lineWidth: Self.stroke, lineJoin: .round))
            }
            PinNeedle().stroke(style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
        }
        .frame(width: Self.size, height: Self.size)
        // Loose, the pin leans over as if not yet pushed in.
        .rotationEffect(.degrees(isPinned ? 0 : 40))
        .accessibilityHidden(true)
    }
}

/// The cap, the shaft and the flared collar of the pin, upright.
private nonisolated struct PinHead: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.move(to: point(5, 1.5))
        path.addLine(to: point(11, 1.5))
        path.addLine(to: point(11, 3.2))
        path.addLine(to: point(10, 3.2))
        path.addLine(to: point(10, 6.8))
        path.addLine(to: point(12.5, 9.8))
        path.addLine(to: point(3.5, 9.8))
        path.addLine(to: point(6, 6.8))
        path.addLine(to: point(6, 3.2))
        path.addLine(to: point(5, 3.2))
        path.closeSubpath()
        return path
    }
}

private nonisolated struct PinNeedle: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8 * unit, y: rect.minY + 9.8 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 8 * unit, y: rect.minY + 14.8 * unit))
        return path
    }
}
