import AppKit
import ApplicationServices

struct Stage: Decodable {
    let pid: Int32
    let token: String
    let operation: String
    let count: Int
    let sequence: Int
    let phase: String
    let generation: Int
    let hitPoint: CGPoint?
}

struct Observation: Encodable {
    let sequence: Int
    let phase: String
    let route: String
    let outcome: String
    let detail: String?
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
    var optionalAttributeErrors: [String: Int] = [:]
    var status: Int32 = 0

    mutating func captureTree(_ reader: AXReader, sequence: Int) {
        guard tree == nil else { return }
        treeSequence = sequence
        tree = reader.treeSummary()
    }

    mutating func record(_ outcome: String, sequence: Int, phase: String, route: String, detail: String? = nil) {
        totals[outcome, default: 0] += 1
        observations.append(.init(sequence: sequence, phase: phase, route: route, outcome: outcome, detail: detail))
        switch outcome {
        case "failure", "processExited": status = 1
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

func waitForFile(_ url: URL, pid: Int32) throws {
    let deadline = ContinuousClock.now + .seconds(100)
    while !FileManager.default.fileExists(atPath: url.path) {
        if kill(pid, 0) != 0 {
            // The app can publish completion and quit between the existence check and the PID check.
            if FileManager.default.fileExists(atPath: url.path) { return }
            throw ProcessExited()
        }
        guard ContinuousClock.now < deadline else { throw Deadline() }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// The current page proves the generation changed. Only the handles acquired at stage zero are retained.
func discover<Page>(_ stage: Stage, report: inout Report, acquire: (Route) throws -> Page) throws -> [Route: Page] {
    let deadline = ContinuousClock.now + .seconds(5)
    var pages: [Route: Page] = [:]
    var missing: [Route: String] = [:]
    repeat {
        for route in Route.allCases {
            do {
                pages[route] = try acquire(route)
                missing.removeValue(forKey: route)
                if stage.sequence != 0 { break }
            } catch let failure as AXFailure where failure.error == .apiDisabled {
                throw failure
            } catch {
                missing[route] = String(describing: error)
                if (error as? AXFailure)?.error == .cannotComplete || error is Deadline {
                    report.record(
                        error is Deadline ? "timeout" : "cannotComplete", sequence: stage.sequence, phase: stage.phase,
                        route: route.rawValue, detail: String(describing: error))
                }
            }
        }
        if !pages.isEmpty || ContinuousClock.now >= deadline { break }
        try requireAlive(stage.pid)
        Thread.sleep(forTimeInterval: 0.15)
    } while true
    for route in Route.allCases {
        if let reason = missing[route] {
            report.record(
                "unavailable", sequence: stage.sequence, phase: stage.phase, route: route.rawValue, detail: reason)
        }
    }
    guard !pages.isEmpty else {
        throw ProbeFailure("All three routes unavailable for generation " + String(stage.generation))
    }
    return pages
}

func run(_ report: inout Report, directory: URL) {
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
        while true {
            let url = directory.appending(path: "stage-\(index).json")
            try waitForFile(url, pid: pid)
            try requireAlive(pid)
            let stage = try JSONDecoder().decode(Stage.self, from: Data(contentsOf: url))
            guard stage.pid == pid, stage.sequence == index, stage.operation == report.operation,
                stage.count == report.count, stage.phase == phase, stage.generation == generation,
                UUID(uuidString: stage.token) != nil, token == nil || stage.token == token,
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "app.surimono.Surimono.debug"
            else { throw ProbeFailure("Unexpected process or stage") }
            token = stage.token
            let reader = AXReader(app: app, token: stage.token)
            readerForDiagnostics = reader
            defer { report.optionalAttributeErrors.merge(reader.optionalErrors, uniquingKeysWith: +) }
            if index == 0 {
                let initial = try discover(stage, report: &report) { route in
                    try HeldPage(reader.page(via: route, stage: stage), token: stage.token)
                }
                held = Dictionary(uniqueKeysWithValues: initial.map { ($0.key.rawValue, $0.value) })
                report.attributes = held.mapValues(\.attributes)
                report.parameterizedAttributes = held.mapValues(\.parameters)
            }
            if phase == "reload" {
                // A stale handle returning old text is meaningful only once the user can see the new text.
                _ = try discover(stage, report: &report) { try reader.page(via: $0, stage: stage) }
            }
            for (route, page) in held.sorted(by: { $0.key < $1.key }) {
                do {
                    try page.verify()
                    report.record("originalText", sequence: index, phase: phase, route: route)
                } catch let error as AXFailure {
                    let outcome: String
                    switch error.error {
                    case .invalidUIElement where index > 0: outcome = "invalidUIElement"
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
            if report.status != 0 { report.captureTree(reader, sequence: index) }
            try Data(stage.token.utf8).write(
                to: directory.appending(path: "ack-\(index)"), options: .withoutOverwriting)
            if phase == "finished" {
                // Between the last AX reply and the application's intentional quit, an exit is still a failure.
                let complete = directory.appending(path: "complete")
                try waitForFile(complete, pid: pid)
                guard try String(contentsOf: complete, encoding: .utf8) == stage.token else {
                    throw ProbeFailure("Missing completion token")
                }
                break
            }
            index += 1
            if (phase == "initial" || phase == "reload") && generation == report.count {
                phase = "finished"
            } else if phase == "inTray" {
                phase = "afterTray"
            } else if (phase == "initial" || phase == "reload") && report.operation != "reload" {
                phase = report.operation == "tray" ? "inTray" : "layout"
            } else {
                phase = "reload"
                generation += 1
            }
        }
    } catch {
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
