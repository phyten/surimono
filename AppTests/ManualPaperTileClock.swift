import Foundation

@testable import Surimono

@MainActor
final class ManualPaperTileClock: PaperTileClock {
    private var instant = ContinuousClock.now
    override var now: ContinuousClock.Instant { instant }
    private var alarms: [UUID: (deadline: ContinuousClock.Instant, action: Action)] = [:]

    override func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping Action) -> Action {
        let id = UUID()
        alarms[id] = (deadline, action)
        return { [weak self] in self?.alarms.removeValue(forKey: id) }
    }

    func advance(by duration: Duration) {
        instant += duration
        for (id, alarm) in alarms where alarm.deadline <= instant {
            alarms.removeValue(forKey: id)
            alarm.action()
        }
    }
}
