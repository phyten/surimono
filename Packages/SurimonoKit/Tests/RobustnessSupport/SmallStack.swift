import Darwin
import Foundation
import SurimonoFormats

/// Runs reader code the way the app does: on a background thread with a 512 KiB stack. The main thread's 8 MiB
/// stack, which tests otherwise run on, hides a recursion that the app's conversions would not survive.
package enum SmallStack {
    /// Under a sanitizer, whose frames are larger, the same headroom as the app's 512 KiB needs a larger stack.
    package static let size = Int(512 * 1024 * StackSpace.sanitizerFactor)

    package enum Outcome<Value: Sendable>: Sendable {
        case finished(Value, Duration)
        /// The reader was still running when the limit passed. Its thread cannot be stopped and keeps running.
        case timedOut
    }

    /// The time an input may take: 5 seconds per 100 KB, and never less than 5 seconds. Debug builds, which the tests
    /// use, are several times slower than the app, so a reader that passes here is comfortably inside it there.
    package static func limit(forBytes count: Int) -> Duration {
        // A sanitizer slows the readers several times over; the limit is about hangs, not speed.
        .seconds(max(5, 5 * Double(count) / 100_000) * (StackSpace.sanitizerFactor > 1 ? 10 : 1))
    }

    private final class Once<Value: Sendable>: @unchecked Sendable {
        // Guarded by `lock`: the worker and the timer race to resume the continuation exactly once.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome<Value>, any Error>?

        init(_ continuation: CheckedContinuation<Outcome<Value>, any Error>) { self.continuation = continuation }

        @discardableResult
        func resume(_ result: Result<Outcome<Value>, any Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result)
            return true
        }
    }

    package static func run<Value: Sendable>(
        limit: Duration, stackSize: Int = size, _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Outcome<Value> {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let thread = Thread {
                let start = ContinuousClock.now
                once.resume(Result { .finished(try body(), ContinuousClock.now - start) })
            }
            thread.stackSize = stackSize
            thread.start()
            let (seconds, attoseconds) = limit.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                once.resume(.success(.timedOut))
            }
        }
    }

    /// Runs an asynchronous operation (the app's PDF, image and WebKit paths are asynchronous) against a deadline.
    /// A task group would wait for an operation that ignores cancellation, so the race is unstructured; on timeout
    /// the operation is cancelled and left to finish on its own.
    package static func withDeadline<Value: Sendable>(
        limit: Duration, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Outcome<Value> {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let task = Task {
                let start = ContinuousClock.now
                do {
                    let value = try await operation()
                    once.resume(.success(.finished(value, ContinuousClock.now - start)))
                } catch {
                    once.resume(.failure(error))
                }
            }
            let (seconds, attoseconds) = limit.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                // Cancellation may run a blocking handler on this thread. Release the caller first.
                if once.resume(.success(.timedOut)) { task.cancel() }
            }
        }
    }

    /// The process's peak resident memory, in bytes.
    package static func peakMemory() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss)
    }
}

/// The documents mutations start from: the samples, the committed fixtures and the LaTeX corpus. They are read from
/// the checkout, so a new fixture joins the run without being listed anywhere.
package enum RobustnessCorpus {
    package static let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
        url.deletingLastPathComponent()
    }

    package static let regressionFolders = ["SurimonoFormatsTests", "SurimonoRenderingTests"].map {
        repository.appendingPathComponent("Packages/SurimonoKit/Tests/\($0)/Fixtures/Robustness", isDirectory: true)
    }

    private static func files(under folder: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// Seed documents of a format, sorted so that every run draws from the same list.
    package static func seeds(for format: DocumentFormat) -> [URL] {
        let folders = [
            repository.appendingPathComponent("Samples"), repository.appendingPathComponent("Snapshots/corpus"),
            repository.appendingPathComponent("Packages/SurimonoKit/Tests"),
        ]
        return folders.flatMap(files(under:)).filter { url in
            !url.path.contains("/Fixtures/Robustness/")
                && DocumentFormat(fileExtension: url.pathExtension) == format
                && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 512 * 1024
        }.sorted { $0.path < $1.path }
    }

    /// Minimised inputs that once crashed or hung a reader, under `Fixtures/Robustness/<format>/`.
    package static func regressions(for format: DocumentFormat) -> [URL] {
        regressionFolders.flatMap { files(under: $0.appendingPathComponent(format.rawValue)) }
            .sorted { $0.path < $1.path }
    }
}

package enum Sanitizer {
    /// Whether the tests run under AddressSanitizer or ThreadSanitizer, which slow the code several times over.
    package static let isActive = StackSpace.sanitizerFactor > 1
}

/// A value that callbacks running on a converter's own thread may change, read by the test after the conversion.
package final class Locked<Value>: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var stored: Value

    package init(_ value: Value) { stored = value }

    package var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
