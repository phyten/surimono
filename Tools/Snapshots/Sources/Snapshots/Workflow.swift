import Darwin
import Foundation

func swapDirectory(_ staged: URL, into dest: URL) throws {
    if fm.fileExists(atPath: dest.path) {
        guard renamex_np(staged.path, dest.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.EIO) }
        try fm.removeItem(at: staged)
    } else {
        try fm.moveItem(at: staged, to: dest)
    }
}
func promote(base: URL, dir: URL, run: Run, rows: [RunCase], report: Report?, ref: String?) throws {
    let baseline = try ScaleBaseline(base: base, scale: run.displayScale)
    guard report == nil || report?.runScale == run.displayScale else {
        throw SnapshotError("Regenerate snapshots-report for the scale of this run before approval")
    }
    let visual = baseline.visual
    try fm.createDirectory(at: visual.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Stage under the same filesystem. A failed historical render cannot replace the last working baseline.
    let stage = base.appendingPathComponent(".runs/staging-" + UUID().uuidString)
    defer { if fm.fileExists(atPath: stage.path) { try? fm.removeItem(at: stage) } }
    if ref == nil, fm.fileExists(atPath: visual.path) {
        try fm.copyItem(at: visual, to: stage)
    } else {
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    }
    var sources = try visualSources(stage)
    var numeric: [(URL, Data)] = []
    let approved = baseline.numeric
    for row in rows {
        let item = row.item
        if let error = row.error { throw SnapshotError("\(item.id): \(error)") }
        if row.capture?.stable == false { throw SnapshotError("Unstable UI capture: \(item.id)") }
        if let reason = row.unavailable, let ref {
            sources[item.id] = "\(ref) · \(reason)"
            continue
        }
        let name = visualName(item, scale: row.scale)
        let input = dir.appendingPathComponent(item.id)
        let source = input.appendingPathComponent(item.kind == .document ? "document.pdf" : name)
        let contents = try Data(contentsOf: source)
        if let report {
            guard let review = report.cases.first(where: { $0.id == item.id }), review.status != .error,
                review.referenceError == nil
            else { throw SnapshotError("Missing or failed report for \(item.id)") }
            if item.kind == .document {
                var doc = try read(Document.self, input.appendingPathComponent("document.json"))
                let text = try Data(contentsOf: input.appendingPathComponent("document.txt"))
                guard digest(text) == doc.textSHA256 else { throw SnapshotError("Run text mismatch: \(item.id)") }
                doc.fidelity = review.fidelity?.metrics
                numeric += [
                    (approved.appendingPathComponent(item.id + ".json"), try encoded(doc)),
                    (approved.appendingPathComponent(item.id + ".txt"), text),
                ]
            }
        }
        try write(contents, stage.appendingPathComponent(name))
        sources[name] = (ref.map { $0 + " " } ?? "") + run.commit + (run.dirty ? " (dirty)" : "")
        sources.removeValue(forKey: item.id)
    }
    try write(try encoded(sources), stage.appendingPathComponent("sources.json"))
    if report != nil && rows.contains(where: { $0.item.kind == .document }) {
        // Per-case environments remain accurate after a partial approval from a different machine.
        let environment = approved.appendingPathComponent("environment.json")
        struct Environment: Codable {
            let macOS: String
            let fonts: [String]
        }
        var environments =
            fm.fileExists(atPath: environment.path) ? try read([String: Environment].self, environment) : [:]
        for row in rows where row.item.kind == .document {
            let doc = try read(Document.self, dir.appendingPathComponent(row.item.id + "/document.json"))
            environments[row.item.id] = Environment(macOS: run.macOS, fonts: doc.fonts)
        }
        numeric.append((environment, try encoded(environments)))
    }
    for (url, data) in numeric { try write(data, url) }
    try swapDirectory(stage, into: visual)
}

@main
enum CLI {
    @MainActor static func main() {
        do { exit(try execute()) } catch {
            FileHandle.standardError.write(Data("snapshots: \(error)\n".utf8))
            exit(2)
        }
    }
    @MainActor static func execute() throws -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let base = root.appendingPathComponent("Snapshots")
        let cases = try SnapshotCase.parse(Data(contentsOf: base.appendingPathComponent("cases.json")))
        let config = try read(Tolerance.self, base.appendingPathComponent("tolerances.json"))
        try config.validate()
        let env = ProcessInfo.processInfo.environment
        let only = (env["ONLY"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let selection = try select(cases, only: only)
        let runs = base.appendingPathComponent(".runs")
        try fm.createDirectory(at: runs, withIntermediateDirectories: true)
        let lock = open(runs.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw SnapshotError("Cannot open snapshot lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotError("Another snapshot command is running") }

        switch args.first {
        case "selfcheck", "selfcheck-files":
            guard args.count == 3 else { throw SnapshotError("Expected two selfcheck arguments") }
            let ui = selection.filter { $0.kind == .ui }
            guard !ui.isEmpty else { throw SnapshotError("No UI cases selected") }
            let first: URL
            let second: URL
            var output: URL?
            if args[0] == "selfcheck-files" {
                guard validSelfCheckRun(args[1]), validSelfCheckRun(args[2]), args[1] != args[2] else {
                    throw SnapshotError("Expected two distinct runs or saved self-check passes")
                }
                first = runs.appendingPathComponent(args[1])
                second = runs.appendingPathComponent(args[2])
            } else {
                guard validID(args[2]) else { throw SnapshotError("Invalid run ID") }
                let folder = runs.appendingPathComponent("selfcheck-" + args[2])
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                print("Self-check: \(folder.path)")
                first = folder.appendingPathComponent("first")
                second = folder.appendingPathComponent("second")
                for pass in [first, second] {
                    try fm.createDirectory(at: pass, withIntermediateDirectories: false)
                    let run = try capture(
                        root: root, app: URL(fileURLWithPath: args[1]), directory: pass,
                        cases: ui, source: root, historical: false)
                    try write(try encoded(run), pass.appendingPathComponent("run.json"))
                }
                output = folder.appendingPathComponent("selfcheck.json")
            }
            let scales = try [first, second].map {
                try read(Run.self, $0.appendingPathComponent("run.json")).displayScale
            }
            let baselines = try Set(scales).sorted().map { try ScaleBaseline(base: base, scale: $0) }
            let force = env["FORCE_SCALE"] == "1"
            print("Self-check passes: \(scales[0])× / \(scales[1])×" + (force ? " (forced comparison)" : ""))
            for baseline in baselines {
                print(
                    baseline.hasVisual
                        ? "Visual baseline: \(baseline.scale)×"
                        : "No visual baseline for \(baseline.scale)×. Review and approve a normal run at this scale.")
            }
            let rows = try selfCheck(
                ui, first: first, second: second, tolerance: config, baselineRoot: base, forceScale: force)
            if let output { try write(try encoded(rows), output) }
            for row in rows where row.fails || row.pixelStatus == .noise {
                let box = row.difference?.bounds.map { "bbox x=\($0.x) y=\($0.y) w=\($0.width) h=\($0.height)" } ?? ""
                print(
                    "\(row.id)  \(row.pixelLabel)  \(row.difference.map { "\($0.pixels) px" } ?? "") \(box) \(row.issues.joined(separator: ", "))"
                )
                for check in row.approved where check.status == .changed {
                    if let b = check.difference.bounds {
                        print(
                            "  baseline vs pass \(check.pass): \(check.difference.pixels) px bbox x=\(b.x) y=\(b.y) w=\(b.width) h=\(b.height)"
                        )
                    }
                }
            }
            let identical = rows.filter { $0.pixelStatus == .identical }.count
            let noise = rows.filter { $0.pixelStatus == .noise }.count
            let changed = rows.filter { $0.pixelStatus == .changed }.count
            print(
                "Self-check: \(rows.count) UI, \(identical) pixel-identical, \(noise) within tolerance, \(changed) above tolerance, \(rows.filter(\.fails).count) failed"
            )
            if baselines.contains(where: { !$0.hasVisual }) { return 3 }
            return rows.contains(where: \.fails) ? 1 : 0
        case "reference":
            try reference(base: base, ids: Set(selection.compactMap(\.reference)))
        case "render", "render-ref":
            guard args.count >= 3 else {
                throw SnapshotError("Expected render APP RUN-ID or render-ref APP WORKTREE REF")
            }
            let app = URL(fileURLWithPath: args[1]).standardizedFileURL
            let historical = args[0] == "render-ref"
            if historical {
                guard args.count == 4, only.isEmpty else {
                    throw SnapshotError("A ref baseline covers the full manifest")
                }
                let source = URL(fileURLWithPath: args[2], isDirectory: true)
                let temp = runs.appendingPathComponent("ref-" + UUID().uuidString)
                try fm.createDirectory(at: temp, withIntermediateDirectories: false)
                var keepDiagnostics = true
                defer {
                    if keepDiagnostics {
                        print("Reference run diagnostics: " + temp.path)
                    } else {
                        try? fm.removeItem(at: temp)
                    }
                }
                let run = try capture(
                    root: root, app: app, directory: temp, cases: cases, source: source, historical: true)
                try write(try encoded(run), temp.appendingPathComponent("run.json"))
                try promote(base: base, dir: temp, run: run, rows: run.cases, report: nil, ref: args[3])
                keepDiagnostics = run.cases.contains { ($0.timeouts ?? 0) > 0 }
            } else {
                guard validID(args[2]), !["latest", "lock"].contains(args[2]) else {
                    throw SnapshotError("Invalid run ID")
                }
                let dir = runs.appendingPathComponent(args[2])
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                let run = try capture(
                    root: root, app: app, directory: dir, cases: selection, source: root, historical: false)
                try write(try encoded(run), dir.appendingPathComponent("run.json"))
                try write(Data((args[2] + "\n").utf8), runs.appendingPathComponent("latest"))
                print("Run: \(dir.path)")
            }
        case "report", "approve":
            let id = try String(contentsOf: runs.appendingPathComponent("latest"), encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard validID(id) else { throw SnapshotError("Invalid latest run pointer") }
            let dir = runs.appendingPathComponent(id)
            let run = try read(Run.self, dir.appendingPathComponent("run.json"))
            let file = dir.appendingPathComponent("report.json")
            if args[0] == "report" {
                let report = try makeReport(base: base, dir: dir, run: run, tolerance: config)
                let data = try encoded(report)
                try write(data, file)
                guard let template = Bundle.module.url(forResource: "report", withExtension: "html") else {
                    throw SnapshotError("Missing report template")
                }
                let html = try String(contentsOf: template, encoding: .utf8).replacingOccurrences(
                    of: "__REPORT_DATA__",
                    with: String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c"))
                let url = dir.appendingPathComponent("report.html")
                try write(Data(html.utf8), url)
                summary(report)
                print(url.path)
                return report.exitCode
            }
            guard fm.fileExists(atPath: file.path) else {
                throw SnapshotError("Generate and read snapshots-report before approval")
            }
            let report = try read(Report.self, file)
            let selected = Set(try select(run.cases.map(\.item), only: only).map(\.id))
            let rows = run.cases.filter { selected.contains($0.item.id) }
            try promote(base: base, dir: dir, run: run, rows: rows, report: report, ref: nil)
            print("Approved \(rows.count) cases from \(id)")
        default:
            throw SnapshotError(
                "Use make snapshots, snapshots-report, snapshots-approve, snapshots-baseline, or snapshots-reference")
        }
        return 0
    }
}
