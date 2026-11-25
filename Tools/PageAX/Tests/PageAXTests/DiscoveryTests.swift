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
            parent: HitNode(role: kAXWindowRole, identifier: "fixture.window", frame: frame), pageFrame: frame,
            parentIsPaperWindow: true, paperAncestorDistance: 1, directlyContainsPaper: true)
    }

    @Test("既知の窓の構成だけを、確認済みの macOS 26 と 27 でヒット経路から除外する")
    func verifiedWindowContentHit() {
        var hit = paperHit()
        for major in [26, 27] {
            #expect(hit.exclusionReason(macOSMajor: major, paperID: "fixture.paper") != nil)
        }
        for major in [15, 28] {
            #expect(hit.exclusionReason(macOSMajor: major, paperID: "fixture.paper") == nil)
        }
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "other.paper") == nil)
        hit.paperAncestorDistance = nil
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
        hit.paperAncestorDistance = 1
        hit.directlyContainsPaper = false
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
    }

    @Test("macOS 27.2.1 の最初の段で記録したヒットは、紙を直接含む窓のグループとして除外する")
    func recordedLayoutHit() throws {
        let url = try #require(Bundle.module.url(forResource: "layout-hit-macos27", withExtension: "json"))
        var hit = try JSONDecoder().decode(HitInspection.self, from: Data(contentsOf: url))
        let paperID = "A11A30E8-ECB5-402D-916A-063911B9C8A3.paper"
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: paperID)?.contains("macOS 27") == true)

        let window = HitNode(
            role: kAXWindowRole, identifier: "surimono.file.v1.861EED17-FFC4-48A0-B21C-3D83BDF9C401",
            frame: CGRect(x: 836, y: 115, width: 659, height: 1002))
        let paper = HitNode(
            role: kAXGroupRole, identifier: paperID, frame: CGRect(x: 836, y: 147, width: 659, height: 932))
        hit.parentIsPaperWindow = hit.parent?.matchesWindow(window)
        hit.directlyContainsPaper = hit.children.contains { paper.matchesAttributes(of: $0) }
        hit.indexInPaperWindow = nil
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: paperID) != nil)
        for mismatch in [
            HitNode(role: kAXButtonRole, identifier: window.identifier, frame: window.frame),
            HitNode(role: kAXWindowRole, identifier: "other.window", frame: window.frame),
            HitNode(role: kAXWindowRole, frame: window.frame),
            HitNode(role: kAXWindowRole, identifier: window.identifier, frame: window.frame?.offsetBy(dx: 1, dy: 0)),
        ] {
            hit.parentIsPaperWindow = hit.parent?.matchesWindow(mismatch)
            #expect(hit.exclusionReason(macOSMajor: 27, paperID: paperID) == nil)
        }
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

    @Test("窓側も無名の祖先に当たるとき、外部の要素は紙を直接含む窓のグループに限る")
    func verifiedAncestorHit() {
        var hit = paperHit(windowID: nil, windowIsAncestor: true)
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") != nil)
        hit.paperAncestorDistance = 2
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
        hit.paperAncestorDistance = nil
        #expect(hit.exclusionReason(macOSMajor: 26, paperID: "fixture.paper") == nil)
    }

    @Test("ボタンの子、窓を照合できない祖先、別の窓のグループはどちらのヒットでも除外しない", arguments: [true, false])
    func unverifiedWindowContent(taggedWindowHit: Bool) {
        var hit = paperHit(windowID: taggedWindowHit ? "fixture.paper" : nil, windowIsAncestor: !taggedWindowHit)
        hit.paperAncestorDistance = 2
        hit.parent = HitNode(role: kAXButtonRole)
        hit.parentIsPaperWindow = false
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
        hit.parent = nil
        hit.parentIsPaperWindow = nil
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
        hit.indexInPaperWindow = 0
        hit.paperAncestorDistance = 1
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
        hit.parent = HitNode(role: kAXWindowRole)
        hit.parentIsPaperWindow = false
        #expect(hit.exclusionReason(macOSMajor: 27, paperID: "fixture.paper") == nil)
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
