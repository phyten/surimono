import Foundation
import Synchronization

/// Shared by all stages and joined parsing threads of a single Finder request.
package final class PreviewConversion: Sendable {
    @TaskLocal package static var current: PreviewConversion?
    private let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant

    // SwaTex cannot interrupt parsing or layout. Count UTF-8 bytes including the definitions repeated at each call.
    package static let maximumFormulaBytes = 2 * 1024
    package static let maximumMathBytes = 16 * 1024
    package static let maximumFormulas = 128
    private let math = Mutex((remainingBytes: maximumMathBytes, remainingCalls: maximumFormulas, exceeded: false))

    package init(deadline: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.deadline = deadline
        self.now = now
    }

    func reserveFormula(bodyBytes: Int, macroBytes: Int) -> Bool {
        math.withLock { budget in
            guard !budget.exceeded, budget.remainingCalls > 0, macroBytes <= Self.maximumFormulaBytes,
                bodyBytes <= Self.maximumFormulaBytes - macroBytes, bodyBytes + macroBytes <= budget.remainingBytes
            else {
                budget.exceeded = true
                return false
            }
            budget.remainingCalls -= 1
            budget.remainingBytes -= bodyBytes + macroBytes
            return true
        }
    }

    package static var isActive: Bool { current != nil }

    package static var expired: Bool {
        guard let current else { return false }
        return current.now() >= current.deadline || StackSpace.isCancelled || current.math.withLock { $0.exceeded }
    }

    package static func check() throws {
        if expired { throw CancellationError() }
    }
}
