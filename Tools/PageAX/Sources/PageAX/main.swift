import AppKit
import ApplicationServices

struct PageReference: Codable {
    let identifier: String
    let characterIndex: Int
    let characterBounds: CGRect?
    var referenceSource: String?
    var elementCharacterBounds: CGRect?
    var referenceUnavailable: String?

    func expectedBounds() throws -> CGRect {
        if let characterBounds, referenceUnavailable == nil { return characterBounds }
        guard characterBounds == nil, referenceUnavailable?.isEmpty == false, let elementCharacterBounds,
            !elementCharacterBounds.isEmpty, !elementCharacterBounds.isInfinite,
            [
                elementCharacterBounds.minX, elementCharacterBounds.minY, elementCharacterBounds.maxX,
                elementCharacterBounds.maxY,
            ].allSatisfy(\.isFinite)
        else { throw ProbeFailure("Missing marker bounds or reference diagnostic for " + identifier) }
        return elementCharacterBounds
    }
}

struct NativeFocus: Codable {
    let windowIdentifier: String?
    let responder: String
    let isPaper: Bool
    let isKeyWindow: Bool
    let isAppActive: Bool
}

struct HitTarget: Codable {
    let point: CGPoint
    let page: String
    let mouseHitsPaper: Bool
    let paperHitIdentifier: String?
    let windowIsPaperAncestor: Bool
    let windowRole: String?
    let windowIdentifier: String?
}

struct Stage: Codable {
    let pid: Int32
    let token: String
    let operation: String
    let count: Int
    let sequence: Int
    let phase: String
    let generation: Int
    var hit: HitTarget?
    var pages: [PageReference] = []
    var nativeFocus: NativeFocus?

    func isReturningFocusWindow(role: String?, identifier: String?) -> Bool {
        guard phase == "afterTray", nativeFocus?.isPaper == true, role == kAXWindowRole,
            let identifier, !identifier.isEmpty
        else { return false }
        return identifier == nativeFocus?.windowIdentifier
    }
}

struct ExpectedStage: Encodable {
    let pid: Int32
    let operation: String
    let count: Int
    let sequence: Int
    let phase: String
    let generation: Int
    let token: String?
    let bundleIdentifier = "app.surimono.Surimono.debug"

    func matches(_ stage: Stage, bundle: String?) -> Bool {
        stage.pid == pid && stage.operation == operation && stage.count == count && stage.sequence == sequence
            && stage.phase == phase && stage.generation == generation && UUID(uuidString: stage.token) != nil
            && (token == nil || stage.token == token) && bundle == bundleIdentifier
    }
}

struct StageMismatch: Encodable {
    let file: String
    let expected: ExpectedStage
    let observed: Stage
    let runningApplicationFound: Bool
    let runningApplicationPID: Int32?
    let runningBundleIdentifier: String?
}

struct Observation: Encodable {
    let sequence: Int
    let phase: String
    let route: String
    let outcome: String
    let detail: String?
}

struct AppStageFailure: Codable, Error, CustomStringConvertible {
    let pid: Int32
    let token: String
    let sequence: Int
    let phase: String
    let kind: String
    let field: String
    let value: String

    var description: String { "Stage \(sequence) (\(phase)): \(kind) at \(field): \(value)" }

    static func read(in directory: URL, pid: Int32, token: String?) throws -> Self? {
        let file = directory.appending(path: "error.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let failure = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard failure.pid == pid, UUID(uuidString: failure.token) != nil, token == nil || token == failure.token
        else { throw ProbeFailure("error.json does not belong to this app session") }
        return failure
    }
}

struct Report: Encodable {
    let pid: Int32
    let operation: String
    let count: Int
    var totals: [String: Int] = [:]
    var attributes: [String: [String]] = [:]
    var parameterizedAttributes: [String: [String]] = [:]
    var observations: [Observation] = []
    var tree: [TreeNode]?
    var treeSequence: Int?
    var appError: AppStageFailure?
    var stageMismatch: StageMismatch?
    var failedDiscoveryStage: Stage?
    var hitInspections: [Int: HitInspection] = [:]
    var optionalAttributeErrors: [String: Int] = [:]
    var status: Int32 = 0

    var unavailableReferences: [Int: [PageReference]] = [:]

    mutating func recordUnavailableReferences(_ stage: Stage) {
        let unavailable = stage.pages.filter { $0.referenceUnavailable != nil }
        if !unavailable.isEmpty {
            unavailableReferences[stage.sequence] = unavailable
            record("referenceUnavailable", sequence: stage.sequence, phase: stage.phase, route: "bounds")
        }
    }

    mutating func recordComparedReferences(_ stage: Stage, verified: [PageReference]) {
        if verified.contains(where: { $0.characterBounds != nil }) {
            record("referenceCompared", sequence: stage.sequence, phase: stage.phase, route: "bounds")
        }
    }

    mutating func finishReferences(_ stage: Stage) {
        if totals["referenceCompared", default: 0] == 0 {
            record(
                "failure", sequence: stage.sequence, phase: stage.phase, route: "bounds",
                detail: "No current external page bounds were verified against PDFKit in this run")
        }
    }

    mutating func recordAppError(_ failure: AppStageFailure) {
        appError = failure
        record("appError", sequence: failure.sequence, phase: failure.phase, route: "app", detail: failure.description)
    }

    mutating func captureTree(_ reader: AXReader, sequence: Int) {
        guard tree == nil else { return }
        treeSequence = sequence
        tree = reader.treeSummary()
    }

    mutating func record(_ outcome: String, sequence: Int, phase: String, route: String, detail: String? = nil) {
        totals[outcome, default: 0] += 1
        observations.append(.init(sequence: sequence, phase: phase, route: route, outcome: outcome, detail: detail))
        switch outcome {
        case "appError", "failure", "processExited": status = 1
        case "cannotComplete", "timeout": if status == 0 { status = 3 }
        case "permissionDenied": status = 2
        default: break
        }
    }
}

struct Deadline: Error, CustomStringConvertible {
    var description: String { "Timed out waiting for the stage or its AX tree" }
}
struct ProcessExited: Error {}

func requireAlive(_ pid: Int32) throws {
    guard kill(pid, 0) == 0 else { throw ProcessExited() }
}

func waitForFile(_ url: URL, pid: Int32, token: String?) throws {
    let deadline = ContinuousClock.now + .seconds(100)
    let directory = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: url.path) {
        if let failure = try AppStageFailure.read(in: directory, pid: pid, token: token) { throw failure }
        if kill(pid, 0) != 0 {
            // The app can publish completion and quit between the existence check and the PID check.
            if FileManager.default.fileExists(atPath: url.path) { return }
            throw ProcessExited()
        }
        guard ContinuousClock.now < deadline else { throw Deadline() }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// A good handle from one route cannot vouch for the element returned by another route.
func discover<Page>(_ stage: Stage, report: inout Report, acquire: (Route) throws -> Page) throws -> [Route: Page] {
    var pages: [Route: Page] = [:]
    for route in Route.allCases {
        do {
            pages[route] = try acquire(route)
        } catch let miss as ContainerHit where route == .hit {
            report.record(
                "hitRouteExcluded", sequence: stage.sequence, phase: stage.phase, route: route.rawValue,
                detail: miss.description)
        } catch {
            report.failedDiscoveryStage = stage
            report.record(
                "routeError", sequence: stage.sequence, phase: stage.phase, route: route.rawValue,
                detail: String(describing: error))
            throw error
        }
    }
    return pages
}

func run(_ report: inout Report, directory: URL) {
    report.totals["referenceUnavailable"] = 0
    report.totals["referenceCompared"] = 0
    let pid = report.pid
    var index = 0
    var generation = 0
    var phase = "initial"
    var token: String?
    var held: [String: HeldPage] = [:]
    var readerForDiagnostics: AXReader?
    do {
        guard AXIsProcessTrusted() else {
            report.record("permissionDenied", sequence: index, phase: phase, route: "reader")
            return
        }
        // Setting the client's default timeout covers the individual page handles as well as the application.
        try checked(AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2), "setMessagingTimeout")
        let app = AXUIElementCreateApplication(pid)
        var knownBundle: String?
        while true {
            let url = directory.appending(path: "stage-\(index).json")
            try waitForFile(url, pid: pid, token: token)
            try requireAlive(pid)
            let stage = try JSONDecoder().decode(Stage.self, from: Data(contentsOf: url))
            let expected = ExpectedStage(
                pid: pid, operation: report.operation, count: report.count, sequence: index, phase: phase,
                generation: generation, token: token)
            // The lookup can transiently return nil for a live process; the identity checked once stays valid
            // while `requireAlive` holds, so a later miss must not fail the stage.
            let running = NSRunningApplication(processIdentifier: pid)
            if let found = running?.bundleIdentifier { knownBundle = found }
            let bundle = knownBundle
            guard expected.matches(stage, bundle: bundle) else {
                report.stageMismatch = StageMismatch(
                    file: url.lastPathComponent, expected: expected, observed: stage,
                    runningApplicationFound: running != nil, runningApplicationPID: running?.processIdentifier,
                    runningBundleIdentifier: bundle)
                throw ProbeFailure("Unexpected process or stage")
            }
            token = stage.token
            let reader = AXReader(app: app, token: stage.token)
            readerForDiagnostics = reader
            defer {
                if reader.returnedFocusWindowCount > 0, let native = stage.nativeFocus {
                    report.record(
                        "focusWindowObserved", sequence: stage.sequence, phase: stage.phase, route: "focus",
                        detail:
                            "Window replies: \(reader.returnedFocusWindowCount), first responder: \(native.responder), key: \(native.isKeyWindow), active: \(native.isAppActive)"
                    )
                }
                report.optionalAttributeErrors.merge(reader.optionalErrors, uniquingKeysWith: +)
                report.hitInspections[stage.sequence] = reader.hitInspection
            }
            if phase != "inTray" && phase != "finished" {
                report.recordUnavailableReferences(stage)
                let current = try discover(stage, report: &report) { route in
                    let page = try HeldPage(reader.page(via: route, stage: stage), stage: stage)
                    try page.verify(current: true)
                    return page
                }
                report.recordComparedReferences(stage, verified: current.values.map(\.reference))
                for route in Route.allCases {
                    if let page = current[route] {
                        report.record(
                            "currentPage", sequence: index, phase: phase, route: route.rawValue,
                            detail: page.reference.identifier)
                    }
                }
                if current[.hit] == nil && held["hit"] != nil {
                    report.failedDiscoveryStage = stage
                    throw ProbeFailure("Previously available hit route stopped returning a fixture page")
                }
                if phase == "initial" {
                    held = Dictionary(uniqueKeysWithValues: current.map { ($0.key.rawValue, $0.value) })
                    report.attributes = held.mapValues(\.attributes)
                    report.parameterizedAttributes = held.mapValues(\.parameters)
                } else if phase == "innerFocus" {
                    held["innerFocus"] = current[.focus]
                }
                if held["hit"] == nil, let hit = current[.hit] { held["hit"] = hit }
            }
            for (route, page) in held.sorted(by: { $0.key < $1.key }) {
                do {
                    try page.verify(current: false, detached: stage.generation > page.generation)
                    report.record("originalText", sequence: index, phase: phase, route: route)
                } catch let error as AXFailure {
                    let outcome: String
                    switch error.error {
                    case .invalidUIElement where index > 0 && phase != "innerFocus": outcome = "invalidUIElement"
                    case .cannotComplete: outcome = "cannotComplete"
                    case .apiDisabled: outcome = "permissionDenied"
                    default: outcome = "failure"
                    }
                    report.record(outcome, sequence: index, phase: phase, route: route, detail: error.description)
                } catch {
                    report.record(
                        "failure", sequence: index, phase: phase, route: route, detail: String(describing: error))
                }
            }
            try requireAlive(pid)
            if phase == "finished" { report.finishReferences(stage) }
            if report.status != 0 { report.captureTree(reader, sequence: index) }
            try Data(stage.token.utf8).write(
                to: directory.appending(path: "ack-\(index)"), options: .withoutOverwriting)
            if phase == "finished" {
                // Between the last AX reply and the application's intentional quit, an exit is still a failure.
                let complete = directory.appending(path: "complete")
                try waitForFile(complete, pid: pid, token: token)
                guard try String(contentsOf: complete, encoding: .utf8) == stage.token else {
                    throw ProbeFailure("Missing completion token")
                }
                break
            }
            index += 1
            if phase == "initial" {
                phase = "innerFocus"
            } else if (phase == "innerFocus" || phase == "reload") && generation == report.count {
                phase = "finished"
            } else if phase == "inTray" {
                phase = "afterTray"
            } else if (phase == "innerFocus" || phase == "reload") && report.operation != "reload" {
                phase = report.operation == "tray" ? "inTray" : "layout"
            } else {
                phase = "reload"
                generation += 1
            }
        }
    } catch {
        // The app can publish its diagnostic and exit between two reader checks, including the final PID check.
        if let failure = (error as? AppStageFailure)
            ?? (try? AppStageFailure.read(in: directory, pid: pid, token: token))
        {
            report.recordAppError(failure)
            return
        }
        let outcome: String
        if kill(pid, 0) != 0 || error is ProcessExited {
            outcome = "processExited"
        } else if error is Deadline {
            outcome = "timeout"
        } else if let failure = error as? AXFailure, failure.error == .cannotComplete {
            outcome = "cannotComplete"
        } else if let failure = error as? AXFailure, failure.error == .apiDisabled {
            outcome = "permissionDenied"
        } else {
            outcome = "failure"
        }
        report.record(outcome, sequence: index, phase: phase, route: "reader", detail: String(describing: error))
        if let readerForDiagnostics, outcome != "processExited", outcome != "permissionDenied" {
            report.captureTree(readerForDiagnostics, sequence: index)
        }
        if let token {
            try? Data(token.utf8).write(to: directory.appending(path: "abort"), options: .withoutOverwriting)
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--check-permission"] {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "アクセシビリティの許可あり" : "アクセシビリティの許可が必要です")
    exit(trusted ? 0 : 2)
}
guard args.count == 5, let pid = Int32(args[0]), pid > 0, ["reload", "layout", "tray"].contains(args[1]),
    let count = Int(args[2]), count > 0
else {
    print("surimono-page-ax PID reload|layout|tray COUNT STAGE_DIRECTORY OUTPUT.json")
    exit(64)
}
let output = URL(fileURLWithPath: args[4])
guard !FileManager.default.fileExists(atPath: output.path) else {
    print("出力先には新しいファイル名を指定してください")
    exit(1)
}
var report = Report(pid: pid, operation: args[1], count: count)
run(&report, directory: URL(fileURLWithPath: args[3]))
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .withoutOverwriting)
} catch {
    print(error.localizedDescription)
    exit(1)
}
if report.status == 2 { print("アクセシビリティの許可が必要です") }
print("JSON: \(output.path), status: \(report.status)")
exit(report.status)
