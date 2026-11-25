import Foundation

@MainActor
class PaperTileClock {
    typealias Action = @MainActor () -> Void

    var now: ContinuousClock.Instant { .now }

    /// A retired paper has no owner left to drive its timers.
    @discardableResult
    func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping Action) -> Action {
        let timer = Task { @MainActor in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { timer.cancel() }
    }
}
