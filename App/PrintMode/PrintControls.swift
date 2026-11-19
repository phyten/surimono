import SwiftUI

/// The washi button of the print mode: raised paper with a hairline that darkens on hover and tints when pressed.
struct PrintBorderedButtonStyle: ButtonStyle {
    enum Size {
        case tray(height: CGFloat)
        case system(CornerPreset, CornerButtonAppearance)
    }

    let size: Size

    init(height: CGFloat = 28) { size = .tray(height: height) }
    init(preset: CornerPreset, appearance: CornerButtonAppearance) { size = .system(preset, appearance) }

    func makeBody(configuration: Configuration) -> some View {
        PrintBorderedButton(configuration: configuration, size: size)
    }
}

private struct PrintBorderedButton: View {
    let configuration: ButtonStyleConfiguration
    let size: PrintBorderedButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Group {
            switch size {
            case .tray(let height):
                let shape = CornerRole.control.shape
                configuration.label.font(.system(size: 12.5)).foregroundStyle(
                    isEnabled ? PrintPalette.ink : PrintPalette.disabledInk
                )
                .emphasisForDisplayContrast(hovering && isEnabled)
                .frame(height: height)
                .background {
                    shape.fill(PrintPalette.raised)
                    if configuration.isPressed { shape.fill(PrintPalette.press) }
                }
                .overlay {
                    shape.strokeBorder(
                        hovering && isEnabled ? PrintPalette.line3 : PrintPalette.line2, lineWidth: 1)
                }
                .contentShape(shape)
            case .system(let preset, let appearance):
                let shape = AppCornerShape(role: .control, preset: preset)
                measuredLabel(appearance)
                    .background {
                        shape.fill(fill(for: appearance))
                        if appearance != .print, appearance != .selected, isEnabled, configuration.isPressed || hovering
                        {
                            shape.fill(configuration.isPressed ? PrintPalette.press : PrintPalette.hover)
                        }
                    }
                    .overlay {
                        if !isEnabled {
                            configuration.label.foregroundStyle(PrintPalette.disabledInk)
                        } else if appearance == .print || appearance == .selected {
                            configuration.label.foregroundStyle(.white)
                        } else {
                            configuration.label
                        }
                    }
                    .emphasisForDisplayContrast(isEnabled && (hovering || appearance == .selected))
                    .contentShape(Rectangle())
                    .contentShape(.focusEffect, shape)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Keep the native padding for each control size, including icon-only Print in the band.
    private func measuredLabel(_ appearance: CornerButtonAppearance) -> some View {
        let measure = Button(action: {}, label: { configuration.label })
        return Group {
            switch appearance {
            case .borderless: measure.buttonStyle(.borderless)
            case .print: measure.buttonStyle(.borderedProminent)
            case .normal, .selected: measure.buttonStyle(.bordered)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func fill(for appearance: CornerButtonAppearance) -> Color {
        if !isEnabled { return PrintPalette.raised }
        return switch appearance {
        case .print:
            configuration.isPressed
                ? PrintPalette.shuPress : hovering && isEnabled ? PrintPalette.shuHover : PrintPalette.shu
        case .selected: PrintPalette.aiControl
        case .borderless: .clear
        case .normal: PrintPalette.press
        }
    }
}

/// A borderless icon button, as on the tray's floating navigator.
struct PrintIconButtonStyle: ButtonStyle {
    var size = CGSize(width: 36, height: 26)

    func makeBody(configuration: Configuration) -> some View {
        PrintIconButton(configuration: configuration, size: size)
    }
}

private struct PrintIconButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? hovering ? PrintPalette.ink : PrintPalette.ink2 : PrintPalette.disabledInk)
            .frame(width: size.width, height: size.height)
            .background {
                CornerRole.smallControl.shape
                    .fill(
                        configuration.isPressed
                            ? PrintPalette.press : hovering && isEnabled ? PrintPalette.hover : .clear)
            }
            .contentShape(CornerRole.smallControl.shape)
            .overlay {
                if hovering && isEnabled && DisplayAccessibility.shared.options.increasedContrast {
                    CornerRole.smallControl.shape.strokeBorder(PrintPalette.line2, lineWidth: 1)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// The seal: the only vermilion element of the window.
struct SealButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SealButton(configuration: configuration)
    }
}

private struct SealButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? .white : PrintPalette.disabledInk)
            .emphasisForDisplayContrast(isEnabled && hovering)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .frame(minWidth: 62)
            .frame(height: 62)
            .background {
                CornerRole.largeControl.shape
                    .fill(
                        !isEnabled
                            ? PrintPalette.raised
                            : configuration.isPressed
                                ? PrintPalette.shuPress : hovering ? PrintPalette.shuHover : PrintPalette.shu
                    )
                    // A step weaker than before, so the seal sits with the washi buttons beside it. The colors stay.
                    .shadow(color: PrintPalette.shuShadow.opacity(0.75), radius: 1, y: 1)
                    .shadow(color: PrintPalette.shuShadow.opacity(0.4), radius: 4, y: 3)
            }
            .overlay {
                CornerRole.tag.shape.strokeBorder(isEnabled ? .white : PrintPalette.line2, lineWidth: 1.25).padding(5)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .contentShape(CornerRole.largeControl.shape)
            .onHover { hovering = $0 }
    }
}

extension EnvironmentValues {
    /// The color of a chosen print setting.
    @Entry var printAccent: Color = PrintPalette.ai
    /// The text on a chosen setting filled with `printAccent`.
    @Entry var printAccentInk: Color = PrintPalette.raised
}

/// A small bordered label, such as the format badge or the front and back tags.
struct PrintTag: View {
    let text: String
    var font: Font = .system(size: 10.5, weight: .semibold)
    var color: Color = PrintPalette.ai
    var border: Color?

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay { CornerRole.tag.shape.strokeBorder(border ?? color, lineWidth: 1) }
    }
}

/// Choices as rows of 28 pt with a radio mark, one chosen. Boxed in gray like `PrintSegments`, five long names read as
/// a menu left open; as plain rows they read as a choice.
struct PrintRadioList<Value: Hashable>: View {
    let label: LocalizedStringKey
    let options: [PrintChoice<Value>]
    let selection: Value?
    let choose: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                PrintRadioRow(title: option.title, isOn: option.value == selection) { choose(option.value) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}

struct PrintRadioRow: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void
    @Environment(\.printAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? accent : PrintPalette.ink3)
                Text(title).font(.system(size: 13, weight: isOn ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A text button in ai, underlined under the pointer, for an action that must not compete with the controls around it.
struct PrintLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrintLinkButton(configuration: configuration)
    }
}

private struct PrintLinkButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.printAccent) private var accent

    var body: some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(accent)
            .underline(hovering || configuration.isPressed)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
