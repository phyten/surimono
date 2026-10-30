import SwiftUI

/// The margin field and stepper, shared by the view options and the tray's print options so both accept the same
/// values and change the margin through the same model call.
struct MarginControl: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        HStack(spacing: 4) {
            TextField("Margins (mm)", value: margin, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            Stepper("Margins (mm)", value: margin, in: DocumentViewModel.marginRange, step: 1).labelsHidden()
        }
    }

    private var margin: Binding<Double> {
        Binding(get: { model.printOptions.marginsInMillimeters }, set: { model.setMargins($0) })
    }
}

/// The margin presets as a submenu of the "…" menu, with the current value checked.
struct MarginMenu: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        Menu {
            Picker(
                "Margins",
                selection: Binding(get: { model.printOptions.marginsInMillimeters }, set: { model.setMargins($0) })
            ) {
                ForEach(model.marginChoices, id: \.self) { millimeters in
                    Text(verbatim: Self.label(millimeters)).tag(millimeters)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(verbatim: choice(String(localized: "Margins"), Self.label(model.printOptions.marginsInMillimeters)))
        }
    }

    /// "15 mm", or "12.5 mm" for a margin typed with a fraction.
    static func label(_ millimeters: Double) -> String {
        String(
            format: String(localized: "%@ mm", comment: "A margin in millimeters"),
            millimeters.formatted(.number.precision(.fractionLength(0...1))))
    }
}
