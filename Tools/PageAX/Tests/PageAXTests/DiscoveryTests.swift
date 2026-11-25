import ApplicationServices
import Foundation
import Testing

@testable import PageAX

struct DiscoveryTests {
    private let token = "11223344-0000-0000-0000-000000000000"
    private var stage: Stage {
        Stage(
            pid: getpid(), token: token, operation: "reload", count: 1, sequence: 0, phase: "initial", generation: 0,
            hit: nil)
    }
    private var report: Report { Report(pid: getpid(), operation: "reload", count: 1) }

    @Test("段の待機中にアプリが残したエラーを、その段・項目・値とともに報告できる")
    func stageFailureFromApp() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = """
            {"pid":\(getpid()),"token":"\(token)","sequence":3,"phase":"afterTray","kind":"nonFinite","field":"hit.point.x","value":"nan"}
            """
        try Data(error.utf8).write(to: directory.appending(path: "error.json"), options: .atomic)
        do {
            try waitForFile(directory.appending(path: "stage-3.json"), pid: getpid(), token: token)
            Issue.record("Expected the app's diagnostic")
        } catch let failure as AppStageFailure {
            var report = report
            report.recordAppError(failure)
            #expect(report.status == 1)
            #expect(report.observations.last?.outcome == "appError")
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            let appError = try #require(json["appError"] as? [String: Any])
            #expect(appError["sequence"] as? Int == 3)
            #expect(appError["phase"] as? String == "afterTray")
            #expect(appError["field"] as? String == "hit.point.x")
            #expect(appError["value"] as? String == "nan")
        }
        #expect(throws: ProbeFailure.self) {
            try AppStageFailure.read(in: directory, pid: getpid(), token: "another session")
        }
    }

    @Test("識別子を読めないメニューボタンとグループの先でも、指定した紙を見つける")
    func discoverPaperByRoleAndIdentifier() throws {
        let reader = AXReader(app: AXUIElementCreateApplication(getpid()), token: token)
        let failure = AXFailure(api: kAXIdentifierAttribute, error: .failure)
        var queried = false
        let menuMatches = try reader.isFixturePaper(role: kAXMenuButtonRole) {
            queried = true
            throw failure
        }
        #expect(!menuMatches && !queried)
        #expect(try !reader.isFixturePaper(role: kAXGroupRole) { throw failure })
        #expect(reader.optionalErrors[failure.description] == 1)
        #expect(try reader.isFixturePaper(role: kAXGroupRole) { token + ".paper" })
        #expect(throws: AXFailure.self) {
            try reader.isFixturePaper(role: kAXGroupRole) {
                throw AXFailure(api: kAXIdentifierAttribute, error: .cannotComplete)
            }
        }
    }

    @Test("一つの経路でも想定外の要素を返したら、その段で失敗する", arguments: Route.allCases)
    func unexpectedRoute(failing: Route) {
        var report = report
        #expect(throws: ProbeFailure.self) {
            _ = try discover(stage, report: &report) { route in
                if route == failing { throw ProbeFailure("Unexpected element") }
                return 42
            }
        }
        #expect(report.observations.last?.route == failing.rawValue)
    }

    @Test("確認済みの親グループに当たった場合だけヒット経路を除外し、理由を残す")
    func knownContainer() throws {
        var report = report
        let pages = try discover(stage, report: &report) { route in
            if route == .hit { throw ContainerHit(description: "verified hosting ancestor") }
            return 42
        }
        #expect(pages == [.children: 42, .focus: 42])
        #expect(report.totals == ["hitRouteExcluded": 1])
        #expect(report.observations.first?.detail == "verified hosting ancestor")
    }

    @Test("ヒット経路を除外した段でも内側のフォーカスが取れなければ失敗する")
    func missingInnerFocusAfterExcludedHit() {
        let inner = Stage(
            pid: getpid(), token: token, operation: "layout", count: 1, sequence: 1,
            phase: "innerFocus", generation: 0)
        var report = report
        #expect(throws: ProbeFailure.self) {
            _ = try discover(inner, report: &report) { route in
                switch route {
                case .children: return 42
                case .hit: throw ContainerHit(description: "verified hosting ancestor")
                case .focus: throw ProbeFailure("No focused page")
                }
            }
        }
        #expect(report.observations.map(\.outcome) == ["hitRouteExcluded", "routeError"])
        #expect(report.failedDiscoveryStage?.phase == "innerFocus")
    }

    private func paperHit(
        windowID: String? = "fixture.paper", windowIsAncestor: Bool = false, hasExternalFrame: Bool = true
    ) -> HitInspection {
        let frame = CGRect(x: 800, y: 200, width: 450, height: 500)
        let target = HitTarget(
            point: CGPoint(x: 891.28, y: 243.56), page: "fixture.page.0", mouseHitsPaper: true,
            paperHitIdentifier: "fixture.page.0", windowIsPaperAncestor: windowIsAncestor,
            windowRole: kAXGroupRole, windowIdentifier: windowID)
        return HitInspection(
            target: target, external: HitNode(role: kAXGroupRole, frame: hasExternalFrame ? frame : nil),
            parent: HitNode(role: kAXWindowRole), pageFrame: frame, paperAncestorDistance: 1)
    }

    @Test("窓が紙自身を返し、外部がその親を返したときは macOS 26 のヒット経路だけを除外する")
    func verifiedWindowContentHit() {
        var hit = paperHit()
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") != nil)
        #expect(hit.exclusionReason(macOSMajor: 15, paperID: "fixture.paper") == nil)
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "other.paper") == nil)
        hit.paperAncestorDistance = nil
        // SwiftUI can expose the paper through AXChildren even if AXParent skips its container.
        hit.directlyContainsPaper = true
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") != nil)
        hit.parent = nil
        hit.indexInPaperWindow = 0
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") != nil)
    }

    @Test("同じ枠の兄弟、手前のボタンの子、紙の外の点、読めない枠は除外しない")
    func unrelatedOrUnverifiedHit() {
        var sibling = paperHit()
        sibling.paperAncestorDistance = nil
        #expect(sibling.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
        var buttonGroup = paperHit()
        buttonGroup.parent = HitNode(role: kAXButtonRole)
        #expect(buttonGroup.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
        var offPage = paperHit()
        offPage.pageFrame = CGRect(x: 0, y: 0, width: 20, height: 20)
        #expect(offPage.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
        let unknown = paperHit(hasExternalFrame: false)
        #expect(unknown.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
    }

    @Test("窓側も無名の祖先に当たる構成は外部が紙の祖先と照合できたときだけ除外する")
    func verifiedAncestorHit() {
        var hit = paperHit(windowID: nil, windowIsAncestor: true)
        hit.paperAncestorDistance = 2
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") != nil)
        hit.paperAncestorDistance = nil
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
    }

    @Test("別経路でページを取得しても応答不能は呼び出し側に返す")
    func cannotComplete() {
        var report = report
        #expect(throws: AXFailure.self) {
            _ = try discover(stage, report: &report) { route in
                if route == .hit { throw AXFailure(api: "hitTest", error: .cannotComplete) }
                return 42
            }
        }
    }

    private static let textParameters = [
        "AXBoundsForRange", "AXStringForRange", "AXAttributedStringForRange", "AXRangeForLine", "AXLineForIndex",
        "AXRangeForIndex", "AXRangeForPosition",
    ]

    @Test("必要なパラメータ付き属性が一つでも欠けると失敗する", arguments: Self.textParameters)
    func missingAttribute(missing: String) {
        let attributes = [
            "AXIdentifier", "AXValue", "AXNumberOfCharacters", "AXRole", "AXPosition", "AXSize", "AXParent",
        ]
        #expect(throws: ProbeFailure.self) {
            try HeldPage.requireContract(
                attributes: attributes, parameters: Self.textParameters.filter { $0 != missing })
        }
    }

    @Test("表示中の文字の矩形はゼロでも別の位置でも失敗する")
    func markerBounds() throws {
        let box = CGRect(x: 40, y: 80, width: 12, height: 14)
        try HeldPage.checkBounds(box, against: box)
        #expect(throws: ProbeFailure.self) { try HeldPage.checkBounds(.zero, against: box) }
        #expect(throws: ProbeFailure.self) { try HeldPage.checkBounds(box.offsetBy(dx: 0, dy: 20), against: box) }
    }

    @Test("見開き検査の第19段は同じアプリとセッションの9回目の再読み込みに一致する")
    func layoutReloadStage() {
        let expected = ExpectedStage(
            pid: 123, operation: "layout", count: 10, sequence: 19, phase: "reload", generation: 9, token: token)
        let reload = Stage(
            pid: 123, token: token, operation: "layout", count: 10, sequence: 19, phase: "reload", generation: 9,
            hit: nil)
        let layout = Stage(
            pid: 123, token: token, operation: "layout", count: 10, sequence: 18, phase: "layout", generation: 8,
            hit: nil)
        #expect(expected.matches(reload, bundle: expected.bundleIdentifier))
        #expect(!expected.matches(reload, bundle: nil))
        #expect(!expected.matches(layout, bundle: expected.bundleIdentifier))
    }

    @Test("世代と実行の目印は改行されても同じ原稿だけに一致する")
    func fixtureMarker() {
        let text = "世代 10。 R01-1122\n3344 紙面の本文です。"
        #expect(AXReader.hasMarker(text, generation: 10, token: token))
        #expect(!AXReader.hasMarker(text, generation: 1, token: token))
        #expect(!AXReader.hasMarker(text, generation: 10, token: "55667788"))
    }
}
