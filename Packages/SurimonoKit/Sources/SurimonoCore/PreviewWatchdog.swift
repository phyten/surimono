import Dispatch
import Foundation
import Synchronization

extension FinderPreview {
    /// Quick Look calls its data producer after the reply object has been handed to the system.
    public static func replyData(
        for url: URL, bundle: Bundle, terminateIfStalled: @escaping @Sendable () -> Void,
        encode: (Self) -> Data
    ) -> Data {
        PreviewWatchdog.shared.watch(
            timeoutMilliseconds: timeoutMilliseconds, grace: .milliseconds(500), bundle: bundle,
            convert: { make(for: url, bundle: bundle, deadline: $0) }, terminateIfStalled: terminateIfStalled,
            encode: encode)
    }
}

final class PreviewWatchdog: Sendable {
    static let shared = PreviewWatchdog()
    private let retired = Mutex(false)

    func watch(
        timeoutMilliseconds: Int, grace: DispatchTimeInterval, bundle: Bundle,
        convert: @escaping @Sendable (ContinuousClock.Instant) -> FinderPreview,
        terminateIfStalled: @escaping @Sendable () -> Void,
        encode: (FinderPreview) -> Data
    ) -> Data {
        guard !retired.withLock({ $0 }) else { return encode(.tooComplex(bundle)) }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        let stopWaiting = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        let state = Mutex((running: false, result: FinderPreview?.none))
        let done = DispatchGroup()
        done.enter()
        let worker = Task.detached(priority: .userInitiated) {
            defer { done.leave() }
            // A queued request must pass admission again when its worker actually starts.
            let shouldStart = self.retired.withLock { retired in
                guard !retired, !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                state.withLock { $0.running = true }
                return true
            }
            guard shouldStart else { return }
            let preview = convert(deadline)
            state.withLock { $0 = (false, preview) }
        }
        if done.wait(timeout: stopWaiting) == .success, ContinuousClock.now < deadline {
            let preview = state.withLock { $0.result } ?? .tooComplex(bundle)
            return encode(preview.boundedReply(bundle: bundle))
        }

        retired.withLock { $0 = true }
        worker.cancel()
        let data = encode(.tooComplex(bundle))
        // Allow the data callback to return and cooperative cleanup to finish. The independent timer must never
        // wait on Swift's worker pool, which may itself be occupied by a stalled native call.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            // A cancelled task still queued in the pool never entered the converter.
            if state.withLock({ $0.running }) { terminateIfStalled() }
        }
        return data
    }
}
