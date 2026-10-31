/// Accumulates deliberate wheel travel, with one turn per finger gesture and no momentum turns.
public struct WheelPageTurner: Sendable {
    public enum Sensitivity: String, CaseIterable, Sendable {
        case low, normal, high

        var wheelThreshold: Double {
            switch self {
            case .low: 4
            case .normal: 3
            case .high: 2
            }
        }

        var gestureThreshold: Double {
            switch self {
            case .low: 120
            case .normal: 80
            case .high: 48
            }
        }

        var interval: Double {
            switch self {
            case .low: 0.5
            case .normal: 0.35
            case .high: 0.22
            }
        }
    }

    public enum Phase: Sendable {
        case discrete, began, changed, ended, cancelled, momentum, momentumEnded
    }

    private var distance: Double = 0
    private var lastInput: Double?
    private var lastTurn: Double?
    private var gestureTurned = false
    private var sensitivity: Sensitivity?
    private var wasDiscrete: Bool?

    public init() {}

    /// Starts another physical operation without discarding the minimum interval between turns.
    public mutating func beginSequence() {
        discardTravel()
        gestureTurned = false
        wasDiscrete = nil
    }

    /// Drops partial travel when the pointer leaves the paper without unlocking an already consumed gesture.
    public mutating func discardTravel() {
        distance = 0
        lastInput = nil
    }

    /// Positive travel means forward. Discrete travel is measured in wheel lines, gestures in points.
    public mutating func update(
        delta: Double, phase: Phase, timestamp: Double, sensitivity: Sensitivity
    ) -> Bool? {
        guard delta.isFinite, timestamp.isFinite else { return nil }
        if self.sensitivity != sensitivity {
            self = Self()
            self.sensitivity = sensitivity
        }
        guard phase != .momentum, phase != .momentumEnded else { return nil }
        let discrete = phase == .discrete
        if phase == .began || wasDiscrete != discrete {
            distance = 0
            gestureTurned = false
        }
        wasDiscrete = discrete
        if let lastInput, timestamp - lastInput > 0.4 || timestamp < lastInput {
            distance = 0
        }
        lastInput = timestamp
        if phase == .ended || phase == .cancelled {
            distance = 0
            return nil
        }
        guard !gestureTurned || discrete else { return nil }
        if let lastTurn, timestamp - lastTurn < sensitivity.interval {
            distance = 0
            return nil
        }
        // Reversing direction starts fresh instead of carrying an old nudge into the next turn.
        if delta * distance < 0 { distance = 0 }
        // Mouse acceleration can report several lines for one notch. It must still take multiple inputs.
        distance += discrete ? min(1, max(-1, delta)) : delta
        let threshold = discrete ? sensitivity.wheelThreshold : sensitivity.gestureThreshold
        guard abs(distance) >= threshold else { return nil }
        let forward = distance > 0
        distance = 0
        lastTurn = timestamp
        gestureTurned = !discrete
        return forward
    }
}
