import Foundation
import Synchronization

/// Shared by all stages and joined parsing threads of a single Finder request.
package final class PreviewConversion: Sendable {
    @TaskLocal package static var current: PreviewConversion?
    private let deadline: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant

    // At the measured expanding-macro rate, 128 KiB costs about 2.6 s. Also meter elapsed
    // typesetting time: short calls have fixed overhead and expansion is not linear in source bytes.
    package static let maximumFormulaBytes = 4 * 1024
    package static let maximumMathBytes = 128 * 1024
    // The eight-term probe produced 1.07 MB from 6,145 glyphs and 1.43 MB from 8,193 glyphs.
    static let maximumFormulaOutput = 1 << 20
    private static let maximumMathOutput = 8 << 20
    static let maximumExpandedTokens = 8_192
    private let math = Mutex(
        (remainingBytes: maximumMathBytes, remainingOutput: maximumMathOutput, time: Duration.zero))
    private static let mathTime: Duration = .seconds(2)

    package init(deadline: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.deadline = deadline
        self.now = now
    }

    func reserveFormula(bodyBytes: Int, macroBytes: Int) -> Bool {
        guard !Self.expired, macroBytes <= Self.maximumFormulaBytes, bodyBytes <= Self.maximumFormulaBytes - macroBytes
        else { return false }
        return math.withLock { budget in
            let bytes = bodyBytes + macroBytes
            guard budget.remainingOutput > 0, budget.time < Self.mathTime else { return false }
            guard bytes <= budget.remainingBytes else {
                budget.remainingBytes = 0
                return false
            }
            budget.remainingBytes -= bytes
            return true
        }
    }

    func retainMathOutput(bytes: Int) -> Bool {
        guard bytes <= Self.maximumFormulaOutput else { return false }
        return math.withLock { budget in
            guard bytes <= budget.remainingOutput else {
                budget.remainingOutput = 0
                return false
            }
            budget.remainingOutput -= bytes
            return true
        }
    }

    func recordMathTime(since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: now())
        math.withLock { $0.time += elapsed }
    }

    package static var isActive: Bool { current != nil }

    package static var expired: Bool {
        guard let current else { return false }
        return current.now() >= current.deadline || StackSpace.isCancelled
    }

    package static func check() throws {
        if expired { throw CancellationError() }
    }
}
