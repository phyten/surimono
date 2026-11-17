import Foundation

/// The unit margins are shown and typed in. They are always stored in millimeters; only the controls change.
public enum MarginUnit: String, CaseIterable, Sendable {
    case millimeters
    case inches

    /// Inches where the region measures in them (the United States and a few others), millimeters elsewhere.
    public static func preferred(for locale: Locale) -> MarginUnit {
        locale.measurementSystem == .us ? .inches : .millimeters
    }

    private var millimetersPerUnit: Double { self == .inches ? 25.4 : 1 }

    /// Decimals shown and kept from a typed value: tenths of a millimeter, hundredths of an inch.
    public var fractionDigits: Int { self == .inches ? 2 : 1 }

    /// How far a stepper's arrow moves, in stored millimeters: 0.5 mm, or 0.05 in (1.27 mm).
    public var stepInMillimeters: Double { self == .inches ? 1.27 : 0.5 }

    /// The margin menu's choices, in this unit.
    public var presets: [Double] { self == .inches ? [0, 0.25, 0.5, 0.75, 1] : [0, 5, 10, 15, 20, 25] }

    /// The margin menu's choices, in the millimeters they store (0.25 in is 6.35 mm).
    public var presetMillimeters: [Double] { presets.map { PageMargins.clamped($0 * millimetersPerUnit) } }

    /// A stored margin moved by whole steps of the arrows. It works on the stored millimeters, not on what the unit
    /// shows: rounding for display would keep the inch arrows from reaching 40 mm and make them drift.
    public func stepped(_ millimeters: Double, by steps: Int) -> Double {
        PageMargins.clamped(millimeters + Double(steps) * stepInMillimeters)
    }

    /// A stored margin as this unit shows it.
    public func value(fromMillimeters millimeters: Double) -> Double {
        rounded(millimeters / millimetersPerUnit)
    }

    /// The millimeters to store for a value shown or typed in this unit: rounded to what the unit shows, then kept in
    /// the margin range. An inch keeps its exact millimeters (0.25 in is 6.35 mm).
    public func millimeters(from value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return PageMargins.clamped(rounded(value) * millimetersPerUnit)
    }

    /// The millimeters for a value a field commits, or nil when it is the value the field shows for `current`. A field
    /// commits what it shows when it loses focus; in inches that is rounded (12.5 mm shows as 0.49 in), and storing it
    /// would quietly turn the margin into 12.45 mm.
    public func millimeters(from value: Double, replacing current: Double?) -> Double? {
        if let current, rounded(value) == self.value(fromMillimeters: current) { return nil }
        return millimeters(from: value)
    }

    /// The menu's choices in stored millimeters: the presets, plus the current margin when it is none of them, even
    /// when it shows like one (12.6 mm and the 0.5 in preset both show as 0.5 in), so the menu checks the current
    /// margin and choosing the preset still sets 12.7 mm.
    public func choices(including millimeters: Double?) -> [Double] {
        let presets = presetMillimeters
        guard let millimeters, !presets.contains(where: { abs($0 - millimeters) < 0.001 }) else { return presets }
        return (presets + [millimeters]).sorted()
    }

    /// The number alone, as the controls show it: "12.5", "15", "0.25", "1".
    public func formatted(_ millimeters: Double, locale: Locale) -> String {
        value(fromMillimeters: millimeters).formatted(
            .number.precision(.fractionLength(0...fractionDigits)).locale(locale).grouping(.never))
    }

    private func rounded(_ value: Double) -> Double {
        let scale = self == .inches ? 100.0 : 10.0
        return (value * scale).rounded() / scale
    }
}
