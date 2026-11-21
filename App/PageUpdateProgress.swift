// The caller supplies monotonic timestamps so the same burst can outlive any individual render task.
nonisolated struct PageUpdateProgress {
    enum State { case inactive, behind, current }
    enum Display: String { case hidden, spinner, text }
    enum Announcement { case started, finished }

    private var start: ContinuousClock.Instant?
    private var announced = false
    private(set) var display = Display.hidden
    private(set) var nextDeadline: ContinuousClock.Instant?

    mutating func update(_ state: State, at now: ContinuousClock.Instant) -> Announcement? {
        guard state == .behind else {
            let finished = state == .current && announced
            self = Self()
            return finished ? .finished : nil
        }
        let origin = start ?? now
        start = origin
        let spinner = origin + .milliseconds(350)
        let speech = origin + .seconds(1)
        let text = origin + .seconds(5)
        display = now >= text ? .text : now >= spinner ? .spinner : .hidden
        nextDeadline = [spinner, speech, text].first { $0 > now }
        if now >= speech && !announced {
            announced = true
            return .started
        }
        return nil
    }
}
