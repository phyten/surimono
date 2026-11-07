import SwiftUI

/// The washi button of the print mode: raised paper with a hairline that darkens on hover and tints when pressed.
struct PrintBorderedButtonStyle: ButtonStyle {
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        PrintBorderedButton(configuration: configuration, height: height)
    }
}

private struct PrintBorderedButton: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(PrintPalette.ink)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(PrintPalette.raised)
                if configuration.isPressed { RoundedRectangle(cornerRadius: 6).fill(PrintPalette.press) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovering && isEnabled ? PrintPalette.line3 : PrintPalette.line2, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
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
            .foregroundStyle(hovering && isEnabled ? PrintPalette.ink : PrintPalette.ink2)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        configuration.isPressed
                            ? PrintPalette.press : hovering && isEnabled ? PrintPalette.hover : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.35)
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
            .foregroundStyle(.white)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .frame(minWidth: 62)
            .frame(height: 62)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        configuration.isPressed
                            ? PrintPalette.shuPress : hovering && isEnabled ? PrintPalette.shuHover : PrintPalette.shu
                    )
                    // A step weaker than before, so the seal sits with the washi buttons beside it. The colors stay.
                    .shadow(color: PrintPalette.shuShadow.opacity(0.75), radius: 1, y: 1)
                    .shadow(color: PrintPalette.shuShadow.opacity(0.4), radius: 4, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.62), lineWidth: 1.25).padding(5)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
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
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(border ?? color, lineWidth: 1) }
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

private struct PrintRadioRow: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? PrintPalette.ai : PrintPalette.ink3)
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

    var body: some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(PrintPalette.ai)
            .underline(hovering)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
