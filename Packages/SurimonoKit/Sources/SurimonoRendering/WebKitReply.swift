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

    static func wait(
        until deadline: ContinuousClock.Instant, start: (@escaping Completion) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw WebPaginator.PaginationError.timedOut }
        let reply = WebKitReply()
        let timer = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            reply.finish(.failure(WebPaginator.PaginationError.timedOut))
        }
        defer { timer.cancel() }
        start { [weak reply] result in
            reply?.finish(ContinuousClock.now < deadline ? result : .failure(WebPaginator.PaginationError.timedOut))
        }
        // Cancellation ends this iteration even when WebKit has lost its callback.
        for await _ in reply.signal.stream {}
        try Task.checkCancellation()
        guard let result = reply.result else { throw WebPaginator.PaginationError.printFailed }
        return try result.get()
    }
}

extension WKWebView {
    @MainActor
    func pdfForPrinting(configuration: WKPDFConfiguration, until deadline: ContinuousClock.Instant) async throws -> Data
    {
        try await WebKitReply<Data>.wait(until: deadline) { reply in
            createPDF(configuration: configuration, completionHandler: reply)
        }
    }

    @MainActor
    func evaluateForPrinting(
        _ script: String, arguments: [String: Any] = [:], world: WKContentWorld = WebPaginator.preparationWorld,
        until deadline: ContinuousClock.Instant
    ) async throws -> Any {
        try await WebKitReply<Any>.wait(until: deadline) { completion in
            callAsyncJavaScript(script, arguments: arguments, in: nil, in: world, completionHandler: completion)
        }
    }
}
