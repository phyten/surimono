/// Content magnification layered over print themes, independent of the paper and viewer zoom.
///
/// Any whole percent within `range` is a text size. The steps are the stops of ⌥⌘+ / ⌥⌘−, the menus and the palette's
/// buttons; from a size between two steps they move to the next step.
public enum TextScale: Sendable {
    public static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public static let range: ClosedRange<Double> = 0.8...2

    public static func larger(than value: Double) -> Double {
        steps.first { $0 > value + tolerance } ?? 2
    }

    public static func smaller(than value: Double) -> Double {
        steps.last { $0 < value - tolerance } ?? 0.8
    }

    /// The nearest whole percent within the range. Every size is kept as `percent / 100`, so the same size is always
    /// the same number and a remembered 113% never looks like a change.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let percent = min(max((value * 100).rounded(), range.lowerBound * 100), range.upperBound * 100)
        return percent / 100
    }

    /// The size as a whole percent, for display and typing.
    public static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    /// The size of a whole percent, clamped to the range.
    public static func scale(percent: Int) -> Double { clamped(Double(percent) / 100) }

    /// The steps, with the current size among them when it is none of them, so a menu can check it.
    public static func choices(including value: Double) -> [Double] {
        steps.contains { abs($0 - value) <= tolerance } ? steps : (steps + [value]).sorted()
    }

    /// Below a hundredth of a percent: sizes are whole percents, which this only keeps from floating-point noise.
    private static let tolerance = 0.000_01
}
