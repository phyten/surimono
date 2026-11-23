import WebKit

/// A WebContent process can disappear without replying. WebKit holds the waiter weakly so a late
/// reply cannot keep its session alive or finish a second operation in the fallback session.
@MainActor
final class WebKitReply<Value> {
    typealias Completion = @MainActor @Sendable (Result<Value, any Error>) -> Void

    private var result: Result<Value, any Error>?
    private let signal = AsyncStream<Void>.makeStream()

    private func finish(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        signal.continuation.finish()
    }

    /// `ended` tells a reply that can no longer come: the page's process has ended. Waiting out the deadline then
    /// held a document for a minute or more before it showed its error.
    static func wait(
        until deadline: ContinuousClock.Instant, ended: @escaping @MainActor () -> String? = { nil },
        start: (@escaping Completion) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        // A process that has already ended answers nothing; one that ends before its reply is taken voids it.
        if let message = ended() { throw WebPaginator.PaginationError.loadFailed(message) }
        guard ContinuousClock.now < deadline else { throw WebPaginator.PaginationError.timedOut }
        let reply = WebKitReply()
        let timer = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            reply.finish(.failure(WebPaginator.PaginationError.timedOut))
        }
        defer { timer.cancel() }
        let watcher = Task {
            while !Task.isCancelled {
                if let message = ended() {
                    reply.finish(.failure(WebPaginator.PaginationError.loadFailed(message)))
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { watcher.cancel() }
        start { [weak reply] result in
            reply?.finish(ContinuousClock.now < deadline ? result : .failure(WebPaginator.PaginationError.timedOut))
        }
        // Cancellation ends this iteration even when WebKit has lost its callback.
        for await _ in reply.signal.stream {}
        try Task.checkCancellation()
        if let message = ended() { throw WebPaginator.PaginationError.loadFailed(message) }
        guard let result = reply.result else { throw WebPaginator.PaginationError.printFailed }
        return try result.get()
    }
}

extension WKWebView {
    /// Why the page's web content process ended, once it has; the paginator's navigation delegate records it.
    @MainActor
    func contentProcessEnded() -> String? {
        (navigationDelegate as? NavigationTracker)?.terminationError
    }

    @MainActor
    func pdfForPrinting(configuration: WKPDFConfiguration, until deadline: ContinuousClock.Instant) async throws -> Data
    {
        // A closure rather than the method itself: Swift 6.3 stops on a MainActor method passed as an argument.
        let ended: @MainActor () -> String? = { self.contentProcessEnded() }
        return try await WebKitReply<Data>.wait(until: deadline, ended: ended) { reply in
            createPDF(configuration: configuration, completionHandler: reply)
        }
    }

    /// A snapshot of `configuration.rect`, or the error that kept it from coming: the process ended, the deadline
    /// passed, the task was cancelled, or WebKit gave none (`emptyDocument`).
    @MainActor
    func snapshotForPrinting(configuration: WKSnapshotConfiguration, until deadline: ContinuousClock.Instant)
        async throws -> NSImage
    {
        let ended: @MainActor () -> String? = { self.contentProcessEnded() }
        return try await WebKitReply<NSImage>.wait(until: deadline, ended: ended) { reply in
            takeSnapshot(with: configuration) { image, error in
                if let image {
                    reply(.success(image))
                } else if let error = error as NSError?, error.domain == WKError.errorDomain,
                    error.code == WKError.Code.webContentProcessTerminated.rawValue
                {
                    // The callback can report the ended process before the navigation delegate hears of it;
                    // a caller must not take this for an ordinary failed snapshot and go on to the PDF.
                    reply(.failure(WebPaginator.PaginationError.loadFailed(error.localizedDescription)))
                } else {
                    reply(.failure(error ?? WebPaginator.PaginationError.emptyDocument))
                }
            }
        }
    }

    @MainActor
    func evaluateForPrinting(
        _ script: String, arguments: [String: Any] = [:], world: WKContentWorld = WebPaginator.preparationWorld,
        until deadline: ContinuousClock.Instant
    ) async throws -> Any {
        let ended: @MainActor () -> String? = { self.contentProcessEnded() }
        return try await WebKitReply<Any>.wait(until: deadline, ended: ended) { completion in
            callAsyncJavaScript(script, arguments: arguments, in: nil, in: world, completionHandler: completion)
        }
    }
}

extension WebPaginator {
    public typealias Reply = @MainActor @Sendable (Swift.Result<Any, any Error>) -> Void

    /// Waits for one reply of a page the app shows itself, as the paginator waits for its own pages: it throws
    /// `PaginationError.timedOut` at the deadline and `PaginationError.loadFailed` with the message of `ended` once
    /// that returns one, and a reply that comes later is dropped. Such a page has a navigation delegate of its own,
    /// so the caller tells here when the page's process has ended.
    public static func reply(
        until deadline: ContinuousClock.Instant, ended: @escaping @MainActor () -> String?,
        start: (@escaping Reply) -> Void
    ) async throws -> Any {
        try await WebKitReply<Any>.wait(until: deadline, ended: ended, start: start)
    }
}
