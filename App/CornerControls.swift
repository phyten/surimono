import SwiftUI

enum CornerButtonAppearance {
    case normal, selected, borderless, print
}

extension View {
    @ViewBuilder func cornerButton(_ preset: CornerPreset, _ appearance: CornerButtonAppearance = .normal) -> some View
    {
        if preset.usesSystemControls {
            switch appearance {
            case .print: buttonStyle(.borderedProminent)
            case .borderless: buttonStyle(.borderless)
            case .normal, .selected: self
            }
        } else {
            buttonStyle(PrintBorderedButtonStyle(preset: preset, appearance: appearance))
        }
    }
}

/// Updating the focus mark must not recreate a picker while AppKit is moving its key segment.
/// Not generic: Swift 6.3's optimizer crashes on the deinit of a private generic `@Observable` class in Release.
@Observable private final class CornerSegmentFocus {
    var value: AnyHashable?
}

/// The native segmented control gives each segment its label's width plus the same padding. Equal widths would
/// truncate a long label beside a short one and put the drawn segments off the ones that take the clicks.
private struct ContentSizedSegments: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? ideal.map(\.width).reduce(0, +),
            height: proposal.height ?? ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let extra = (bounds.width - ideal.reduce(0, +)) / CGFloat(subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, ideal) {
            let segment = max(0, width + extra)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: segment, height: bounds.height))
            x += segment
        }
    }
}

/// Keep the native picker's sizing and accessibility vocabulary when the bezel is drawn by the app.
struct CornerSegments<Value: Hashable, Segment: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let values: [Value]
    let preset: CornerPreset
    @ViewBuilder let segment: (Value) -> Segment
    @Environment(\.layoutDirection) private var direction
    @State private var keySegment = CornerSegmentFocus()

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(values, id: \.self) { value in segment(value).tag(value) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .modifier(
            CornerBezel(preset: preset, role: .segmentGroup) { focused in
                ContentSizedSegments {
                    ForEach(values, id: \.self) { value in
                        let selected = selection == value
                        let shape = AppCornerShape(role: .segment, preset: preset)
                        segment(value).lineLimit(1)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .selectionRule(selected, color: .white)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(shape.fill(selected ? PrintPalette.aiControl : .clear))
                            .overlay {
                                if focused, value == ((keySegment.value as? Value) ?? selection) {
                                    shape.strokeBorder(
                                        DisplayAccessibility.focusColor(onSelectedControl: selected), lineWidth: 2)
                                }
                            }
                    }
                }
                .background(AppCornerShape(role: .segmentGroup, preset: preset).fill(PrintPalette.hover))
                .onChange(of: focused) { keySegment.value = nil }
            }
        )
        .onChange(of: selection) { keySegment.value = nil }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
            // AppKit moves the key segment with an arrow and selects it with Space. Only mirror the focus ring.
            let current = (keySegment.value as? Value) ?? selection
            if !preset.usesSystemControls, let index = values.firstIndex(of: current) {
                let forward = (key.key == .rightArrow) == (direction == .leftToRight)
                keySegment.value = values[(index + (forward ? 1 : values.count - 1)) % values.count]
            }
            return .ignored
        }
    }
}

struct CornerMenuPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [PrintChoice<Value>]
    let preset: CornerPreset

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
        }
        .labelsHidden()
        .modifier(
            CornerBezel(preset: preset, role: .control) { _ in
                HStack(spacing: 4) {
                    if let current = options.first(where: { $0.value == selection }) {
                        Text(current.title).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .padding(.horizontal, 7)
                .frame(maxHeight: .infinity)
                .background(AppCornerShape(role: .control, preset: preset).fill(PrintPalette.hover))
            })
    }
}

/// Replace only the drawing. The native control owns sizing, tracking, keyboard focus and accessibility.
struct CornerBezel<Face: View>: ViewModifier {
    let preset: CornerPreset
    let role: CornerRole?
    @ViewBuilder let face: (Bool) -> Face
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var hovered = false
    @GestureState private var pressed = false

    func body(content: Content) -> some View {
        if preset.usesSystemControls {
            content
        } else {
            let shape = AppCornerShape(role: role, preset: preset)
            content
                .focused($focused)
                // A visual effect hides only the bezel. Hiding the view itself also disables mouse tracking in AppKit.
                .visualEffect { drawing, _ in drawing.opacity(0) }
                .overlay {
                    ZStack {
                        face(focused)
                        if enabled, pressed || hovered {
                            if DisplayAccessibility.shared.options.reduceTransparency
                                || DisplayAccessibility.shared.options.increasedContrast
                            {
                                shape.strokeBorder(PrintPalette.line3, lineWidth: 2)
                            } else {
                                shape.fill(pressed ? PrintPalette.press : PrintPalette.hover)
                            }
                        }
                        if focused, role != .segmentGroup {
                            shape.strokeBorder(DisplayAccessibility.focusColor(), lineWidth: 2)
                        }
                    }
                    .saturation(enabled ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onHover { hovered = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
        }
    }
}

struct CornerSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let preset: CornerPreset

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .modifier(
                CornerBezel(preset: preset, role: nil) { _ in
                    let shape = AppCornerShape(role: nil, preset: preset)
                    shape.fill(isOn ? PrintPalette.aiControl : PrintPalette.line3)
                        .overlay(alignment: isOn ? .trailing : .leading) {
                            shape.fill(.white).aspectRatio(1, contentMode: .fit).padding(2)
                        }
                })
    }
}
