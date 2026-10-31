/// Keeps scroll ownership at its starting surface, including momentum after fingers lift.
public struct WheelSequence: Sendable {
    public struct Decision: Sendable {
        public let owns: Bool
        public let startsSequence: Bool
    }

    private var owner: Bool?
    private var discrete = false
    private var fingersEnded = false
    private var lastInput: Double?

    public init() {}

    public mutating func update(
        phase: WheelPageTurner.Phase, timestamp: Double, startsOnPaper: Bool
    ) -> Decision {
        if phase == .momentum || phase == .momentumEnded {
            // An unobserved gesture is never claimed from its current pointer position.
            let owns = owner ?? false
            if phase == .momentumEnded { self = Self() }
            return Decision(owns: owns, startsSequence: false)
        }
        if phase == .ended || phase == .cancelled {
            let owns = owner ?? false
            if phase == .cancelled { self = Self() } else { fingersEnded = true }
            return Decision(owns: owns, startsSequence: false)
        }
        let isDiscrete = phase == .discrete
        let expired = lastInput.map { timestamp - $0 > 0.4 || timestamp < $0 } ?? true
        let starts =
            phase == .began || owner == nil || discrete != isDiscrete
            || (isDiscrete && expired) || (phase == .changed && fingersEnded)
        if starts {
            owner = startsOnPaper
            discrete = isDiscrete
            fingersEnded = false
        }
        lastInput = timestamp
        let owns = owner ?? false
        return Decision(owns: owns, startsSequence: starts)
    }
}
