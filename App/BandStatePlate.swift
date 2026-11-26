import SurimonoCore
import SwiftUI

enum BandDesign {
    static func argument(_ name: String) -> String? {
        #if DEBUG
            DebugSnapshot.argument(name)
        #else
            nil
        #endif
    }

    static func plateRadius(_ corners: CornerPreset) -> CGFloat {
        switch corners {
        case .square: 0
        case .standard: 5
        case .round: 11
        }
    }

    static func hintRadius(_ corners: CornerPreset) -> CGFloat {
        switch corners {
        case .square: 0
        case .standard: 5
        case .round: 8
        }
    }
}

extension EnvironmentValues {
    @Entry var bandPlateCorners: CornerPreset = .standard
    @Entry var bandPartHovered = false
    @Entry var bandSegmentPressed = false
}

struct BandStatePlate: ButtonStyle {
    let on: Bool
    var compact = false
    var hasChanges = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(
            BandPlateFace(on: on, compact: compact, pressed: configuration.isPressed, hasChanges: hasChanges))
    }
}

struct BandPlateFace: ViewModifier {
    let on: Bool
    var compact = false
    var pressed = false
    var hasChanges = false
    @Environment(\.bandPlateCorners) private var corners
    @Environment(\.bandPartHovered) private var hovered
    @Environment(\.bandSegmentPressed) private var segmentPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let marked = on && (DisplayAccessibility.shared.options.increasedContrast || differentiate)
        let down = enabled && (pressed || (segmentPressed && hovered))
        let over = enabled && hovered
        let foreground = on ? PrintPalette.bandOnInk : PrintPalette.ink.opacity(0.85)
        let paint = BandPlatePaint(dark: dark, hovered: over, pressed: down)
        let metrics = BandPlateMetrics(corners: corners, compact: compact)
        let shape = RoundedRectangle(cornerRadius: metrics.radius)
        content
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, metrics.padding)
            .frame(width: metrics.width, height: metrics.height)
            .background(
                shape.fill(
                    on ? PrintPalette.bandPlateFill.opacity(paint.fill) : PrintPalette.ink.opacity(paint.offFill))
            )
            .overlay {
                if marked { shape.strokeBorder(foreground, lineWidth: 1) }
            }
            .overlay(alignment: .bottom) {
                if marked { Capsule().fill(foreground).frame(width: 10, height: 2).padding(.bottom, 1) }
            }
            .overlay(alignment: .topTrailing) {
                if hasChanges {
                    Circle().fill(PrintPalette.ai).frame(width: 4, height: 4).padding(3)
                }
            }
            .contentShape(Rectangle())
            .contentShape(.focusEffect, shape)
            .compositingGroup().opacity(enabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: on)
    }
}

/// Opacities are independent of layout and of the saved value when a control is disabled.
struct BandPlatePaint {
    let dark: Bool
    let hovered: Bool
    let pressed: Bool

    var fill: Double {
        if pressed { return dark ? 0.44 : 0.32 }
        if hovered { return dark ? 0.38 : 0.27 }
        return dark ? 0.32 : 0.22
    }

    var offFill: Double {
        if pressed { return dark ? 0.18 : 0.12 }
        if hovered { return dark ? 0.10 : 0.06 }
        return 0
    }
}

extension BandLayout.Item {
    func stateSymbol(on: Bool) -> String? {
        switch self {
        case .showOnAllSpaces: on ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle"
        case .cover: on ? "book.closed.fill" : "book.closed"
        case .ignoreSlides: on ? "play.rectangle.fill" : "play.rectangle"
        case .selectText: "character.cursor.ibeam"
        case .readingSettings: "sidebar.right"
        case .outline: "list.bullet"
        case .thumbnails: "square.grid.2x2"
        case .style: "paintpalette"
        case .viewOptions: "slider.horizontal.3"
        case .printSettings: "doc.badge.gearshape"
        default: nil
        }
    }
}

/// Both drawings occupy the same grid, even for symbols with different intrinsic widths.
struct BandStateGlyph: View {
    let item: BandLayout.Item
    let on: Bool

    var body: some View {
        Group {
            if item == .floatOnTop {
                ZStack {
                    PinGlyph(isPinned: false).opacity(on ? 0 : 1)
                    PinGlyph(isPinned: true).opacity(on ? 1 : 0)
                }
            } else if item == .alwaysShowToolbar {
                ZStack {
                    ToolbarOutline().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    ToolbarStrip().fill().opacity(on ? 1 : 0)
                }
            } else if let off = item.stateSymbol(on: false), let active = item.stateSymbol(on: true) {
                ZStack {
                    Image(systemName: off).opacity(on && off != active ? 0 : 1)
                    if active != off { Image(systemName: active).opacity(on ? 1 : 0) }
                }
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private nonisolated struct ToolbarOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: 1, y: 2, width: 14, height: 12), cornerRadius: 2)
        path.move(to: CGPoint(x: 1, y: 6.5))
        path.addLine(to: CGPoint(x: 15, y: 6.5))
        return path
    }
}

private nonisolated struct ToolbarStrip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: CGRect(x: 1, y: 2, width: 14, height: 12), cornerRadius: 2)
            .intersection(Path(CGRect(x: 0, y: 1, width: 16, height: 5.5)))
    }
}

/// The represented switch provides the accessible value exactly once.
struct BandSwitchStyle: ToggleStyle {
    let compact: Bool
    let name: LocalizedStringKey

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(BandStatePlate(on: configuration.isOn, compact: compact))
        .accessibilityRepresentation { Toggle(name, isOn: configuration.$isOn) }
    }
}

/// Describes only the plate's footprint. An active state changes paint, never layout.
struct BandPlateMetrics: Equatable {
    let corners: CornerPreset
    let compact: Bool
    var radius: CGFloat { BandDesign.plateRadius(corners) }
    var height: CGFloat { 22 }
    var padding: CGFloat { compact ? 0 : 6 }
    var width: CGFloat? { compact ? 22 : nil }
}
