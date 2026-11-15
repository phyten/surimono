import SurimonoCore
import SwiftUI

/// The text size as a number: any whole percent of the range, typed or stepped by 1%. The menus, the palette's buttons
/// and ⌥⌘+ / ⌥⌘− keep moving through the steps.
struct TextSizeField: View {
    let title: LocalizedStringKey
    let scale: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 3) {
            TextField(title, value: percent, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 40)
            // The unit follows the stepper, as in the margin field beside it.
            Stepper(
                title, value: percent,
                in: TextScale.percent(TextScale.range.lowerBound)...TextScale.percent(TextScale.range.upperBound),
                step: 1
            )
            .labelsHidden()
            Text(verbatim: "%").foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var percent: Binding<Int> {
        Binding(get: { TextScale.percent(scale) }, set: { onChange(TextScale.scale(percent: $0)) })
    }
}
