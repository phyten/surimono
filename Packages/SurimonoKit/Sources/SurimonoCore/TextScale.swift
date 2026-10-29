/// Content magnification layered over print themes, independent of the paper and viewer zoom.
public enum TextScale: Sendable {
    public static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    public static func larger(than value: Double) -> Double {
        steps.first { $0 > value } ?? 2
    }

    public static func smaller(than value: Double) -> Double {
        steps.last { $0 < value } ?? 0.8
    }
}
