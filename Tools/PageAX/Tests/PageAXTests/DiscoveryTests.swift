import ApplicationServices
import Foundation
import Testing

@testable import PageAX

struct DiscoveryTests {
    private let token = "11223344-0000-0000-0000-000000000000"
    private var stage: Stage {
        Stage(
            pid: getpid(), token: token, operation: "reload", count: 1, sequence: 0, phase: "initial", generation: 0,
            hitPoint: nil)
    }
    private var report: Report { Report(pid: getpid(), operation: "reload", count: 1) }

    @Test("一経路だけ取得できたときはその要素を残し、残りの経路を取得不可と記録する", arguments: Route.allCases)
    func oneRoute(available: Route) throws {
        var report = report
        let pages = try discover(stage, report: &report) { route in
            guard route == available else { throw AXFailure(api: "lookup", error: .noValue) }
            return 42
        }
        #expect(pages == [available: 42])
        #expect(report.status == 0)
        #expect(report.totals == ["unavailable": 2])
        #expect(report.observations.allSatisfy { $0.detail == "lookup: kAXErrorNoValue (-25212)" })
    }

    @Test("どの経路にもページがないときは三件の取得不可を記録して失敗する")
    func noRoutes() {
        var report = report
        #expect(throws: ProbeFailure.self) {
            _ = try discover(stage, report: &report) { _ -> Int in throw ProbeFailure("No page") }
        }
        #expect(report.observations.map(\.route) == ["children", "hit", "focus"])
        #expect(report.totals == ["unavailable": 3])
    }

    @Test("別経路で取得できても応答不能は成功に数えない")
    func cannotComplete() throws {
        var report = report
        let pages = try discover(stage, report: &report) { route in
            if route == .hit { throw AXFailure(api: "hitTest", error: .cannotComplete) }
            return 42
        }
        #expect(pages.count == 2)
        #expect(report.status == 3)
        #expect(report.totals["cannotComplete"] == 1)
        #expect(report.observations.first?.detail == "hitTest: kAXErrorCannotComplete (-25204)")
    }

    @Test("世代と実行の目印は改行されても同じ原稿だけに一致する")
    func fixtureMarker() {
        let text = "世代 10。 R01-1122\n3344 紙面の本文です。"
        #expect(AXReader.hasMarker(text, generation: 10, token: token))
        #expect(!AXReader.hasMarker(text, generation: 1, token: token))
        #expect(!AXReader.hasMarker(text, generation: 10, token: "55667788"))
    }
}
