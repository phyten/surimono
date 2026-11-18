import SurimonoCore
import SwiftUI

/// The text size as a number: any whole percent of the range, typed or stepped by 1%. The menus, the palette's buttons
/// and ⌥⌘+ / ⌥⌘− keep moving through the steps.
struct TextSizeField: View {
    let title: LocalizedStringKey
    let scale: Double
    var corners: CornerPreset = .standard
    let onChange: (Double) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if corners.usesSystemControls {
                    field
                } else {
                    let shape = AppCornerShape(role: .smallControl, preset: corners)
                    field.textFieldStyle(.plain)
                        .focused($focused)
                        .padding(.horizontal, 3)
                        .frame(maxHeight: .infinity)
                        .background(shape.fill(Color(nsColor: .textBackgroundColor)))
                        .overlay {
                            shape.strokeBorder(
                                focused ? Color(nsColor: .keyboardFocusIndicatorColor) : PrintPalette.line2,
                                lineWidth: focused ? 2 : 1
                            )
                            .allowsHitTesting(false)
                        }
                }
            }
            .frame(width: 40)
            // The unit follows the stepper, as in the margin field beside it.
            Stepper(
                title, value: percent,
                in: TextScale.percent(TextScale.range.lowerBound)...TextScale.percent(TextScale.range.upperBound),
                step: 1
            )
            .labelsHidden()
            .modifier(
                CornerBezel(preset: corners, role: .smallControl) { _ in
                    AppCornerShape(role: .smallControl, preset: corners).fill(PrintPalette.hover)
                        .overlay {
                            VStack(spacing: 1) {
                                Image(systemName: "chevron.up")
                                Image(systemName: "chevron.down")
                            }
                            .font(.system(size: 7, weight: .semibold))
                        }
                })
            Text(verbatim: "%").foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var field: some View {
        TextField(title, value: percent, format: .number.grouping(.never))
            .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
    }

    private var percent: Binding<Int> {
        Binding(get: { TextScale.percent(scale) }, set: { onChange(TextScale.scale(percent: $0)) })
    }
}
