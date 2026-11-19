import SurimonoCore
import SwiftUI

extension MarginUnit {
    /// The unit of this Mac's region: inches where it measures in them, millimeters elsewhere.
    static var current: MarginUnit { preferred(for: .current) }

    /// The unit's short name, beside a field.
    var symbol: String {
        self == .inches ? String(localized: "in", comment: "Inches, beside a margin field") : String(localized: "mm")
    }

    /// The title of a margin field, with its unit.
    var fieldTitle: LocalizedStringKey { self == .inches ? "Margins (in)" : "Margins (mm)" }

    /// "15 mm", "12.5 mm", or "0.25 in".
    func label(_ millimeters: Double, locale: Locale = .current) -> String {
        let format =
            self == .inches
            ? String(localized: "%@ in", comment: "A margin in inches")
            : String(localized: "%@ mm", comment: "A margin in millimeters")
        return String(format: format, formatted(millimeters, locale: locale))
    }
}

/// A margin field with a stepper in the region's unit, shared by the view options, the print screen and Settings so
/// all of them accept the same values. Typed values keep the unit's decimals; the arrows move by the unit's step.
struct MarginField: View {
    let title: LocalizedStringKey
    /// Nil while the four margins differ: the field then shows them as mixed.
    let millimeters: Double?
    /// Where the stepper starts from while the field shows mixed margins.
    var stepperMillimeters: Double?
    let unit: MarginUnit
    var showsUnit = true
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Uneven margins show as mixed, and typing a value here evens them out.
            TextField(
                title, value: typed, format: .number.precision(.fractionLength(0...unit.fractionDigits)),
                prompt: Text("Mixed")
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            // The arrows move the stored millimeters; what the field shows is rounded and would make them drift.
            Stepper(title) {
                onChange(unit.stepped(stepBase, by: 1))
            } onDecrement: {
                onChange(unit.stepped(stepBase, by: -1))
            }
            .labelsHidden()
            if showsUnit { Text(verbatim: unit.symbol).foregroundStyle(PrintPalette.ink2) }
        }
    }

    private var typed: Binding<Double?> {
        Binding(
            get: { millimeters.map(unit.value(fromMillimeters:)) },
            set: { value in
                if let value, let millimeters = unit.millimeters(from: value, replacing: self.millimeters) {
                    onChange(millimeters)
                }
            })
    }

    private var stepBase: Double { millimeters ?? stepperMillimeters ?? 0 }
}

/// The margin presets as a submenu of the "…" menu, with the current value checked. The choices are stored
/// millimeters, so choosing a preset always sets it, also when the current margin shows like it.
struct MarginMenu: View {
    @Bindable var model: DocumentViewModel
    let unit: MarginUnit

    var body: some View {
        Menu {
            MarginChoices(model: model, unit: unit)
        } label: {
            Text(
                verbatim: choice(
                    String(localized: "Margins"),
                    model.printOptions.margins.uniformValue.map { unit.label($0) } ?? String(localized: "Mixed")))
        }
    }
}

/// The same presets and binding in the band chip and in the complete index.
struct MarginChoices: View {
    @Bindable var model: DocumentViewModel
    let unit: MarginUnit

    var body: some View {
        Picker(
            "Margins",
            selection: Binding(
                get: { model.printOptions.margins.uniformValue },
                set: { if let millimeters = $0 { model.setMargins(millimeters) } })
        ) {
            ForEach(model.marginChoices(in: unit), id: \.self) { millimeters in
                Text(verbatim: unit.label(millimeters)).tag(Optional(millimeters))
            }
        }
        .pickerStyle(.inline).labelsHidden()
    }
}
