import Dispatch
import Foundation
import Synchronization

extension FinderPreview {
    /// Quick Look calls its data producer after the reply object has been handed to the system.
    public static func replyData(
        for url: URL, bundle: Bundle, terminateIfStalled: @escaping @Sendable () -> Void,
        encode: (Self) -> Data
    ) -> Data {
        watch(
            timeoutMilliseconds: timeoutMilliseconds, grace: .milliseconds(500), bundle: bundle,
            convert: { make(for: url, bundle: bundle, deadline: $0) }, terminateIfStalled: terminateIfStalled,
            encode: encode)
    }

    static func watch(
        timeoutMilliseconds: Int, grace: DispatchTimeInterval, bundle: Bundle,
        convert: @escaping @Sendable (ContinuousClock.Instant) -> Self,
        terminateIfStalled: @escaping @Sendable () -> Void,
        encode: (Self) -> Data
    ) -> Data {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        let stopWaiting = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        let state = Mutex((running: false, result: Self?.none))
        let done = DispatchGroup()
        done.enter()
        let worker = Task.detached(priority: .userInitiated) {
            defer { done.leave() }
            let shouldStart = state.withLock {
                $0.running = !Task.isCancelled
                return $0.running
            }
            guard shouldStart else { return }
            let preview = convert(deadline)
            state.withLock { $0 = (false, preview) }
        }
        if done.wait(timeout: stopWaiting) == .success, ContinuousClock.now < deadline,
            let preview = state.withLock({ $0.result })
        {
            return encode(preview)
        }

        worker.cancel()
        let message = bundle.localizedString(forKey: "This document is too complex to preview.", value: nil, table: nil)
        let data = encode(errorPage(message))
        // Allow the data callback to return and cooperative cleanup to finish. The independent timer must never
        // wait on Swift's worker pool, which may itself be occupied by a stalled native call.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            // A cancelled task still queued in the pool never entered the converter.
            if state.withLock({ $0.running }) { terminateIfStalled() }
        }
        return data
    }
}
