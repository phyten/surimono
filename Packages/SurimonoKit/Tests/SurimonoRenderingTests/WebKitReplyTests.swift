import Foundation
import Testing

@testable import SurimonoRendering

@MainActor
struct WebKitReplyTests {
    @Test("届かない応答を期限で打ち切り、後から来た応答を次の測定に渡さない")
    func lateReply() async throws {
        var late: WebKitReply<Int>.Completion?
        let start = ContinuousClock.now
        await #expect(throws: WebPaginator.PaginationError.timedOut) {
            try await WebKitReply<Int>.wait(until: start + .milliseconds(30)) { late = $0 }
        }
        #expect(start.duration(to: .now) < .seconds(1))
        let value = try await WebKitReply<Int>.wait(until: .now + .seconds(1)) { reply in
            late?(.success(1))
            reply(.success(2))
        }
        #expect(value == 2)
    }

    @Test("高さがゼロまたは有限でない測定を段の配置前に検出する", arguments: [CGFloat.zero, .nan, .infinity])
    func invalidMeasurement(height: CGFloat) {
        let item = LaTeXFlowLayout.Item(slice: .init(strip: 0, start: 0, end: height, width: 80))
        let measurement = LaTeXFlowLayout.Measurement(
            segments: [.init(columns: 2, gap: 4, rule: 0, balance: true, pageNotes: false, items: [item])],
            notes: [:], noteSkip: 5, textFloatSep: 10, floatSep: 8, inTextSep: 8)
        #expect(throws: LaTeXFlowLayout.CannotFit.self) {
            try LaTeXFlowLayout.pages(measurement, width: 160, height: 200)
        }
    }

    @Test("応答を待っている組版を取り消すと締切の前に終了する")
    func cancellation() async throws {
        let began = AsyncStream<Void>.makeStream()
        let task = Task {
            try await WebKitReply<Int>.wait(until: .now + .seconds(30)) { _ in began.continuation.finish() }
        }
        for await _ in began.stream {}
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("プロセスが終わったあとの応答の待ちは、始める前と結果を採る前に終了のエラーになる")
    func endedProcess() async throws {
        await #expect(throws: WebPaginator.PaginationError.loadFailed("ended")) {
            try await WebKitReply<Int>.wait(
                until: .now + .seconds(30), ended: { "ended" }, start: { reply in reply(.success(1)) })
        }
        var ended: String?
        await #expect(throws: WebPaginator.PaginationError.loadFailed("ended late")) {
            try await WebKitReply<Int>.wait(
                until: .now + .seconds(30), ended: { ended },
                start: { reply in
                    // The process ends between the reply and its being taken.
                    ended = "ended late"
                    reply(.success(1))
                })
        }
    }
}
