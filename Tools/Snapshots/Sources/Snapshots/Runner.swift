import AppKit
import Darwin
import ImageIO

let debugDomain = "io.github.phyten.Surimono.debug"
struct LayoutScreen: Codable {
    let displayID: UInt32
    let backingScale: Double
}

struct TimeoutRecord: Codable {
    let readiness: String?
    let sample: String?
    let diagnostic: String?
}

struct AttemptTimeout: Error {
    let record: TimeoutRecord
    let reason: String
}

struct RunCase: Codable {
    var item: SnapshotCase
    var scale: Double?
    var capture: CaptureObservation?
    var error: String?
    var unavailable: String?
    var timeouts: Int?
    var timeoutDetails: [TimeoutRecord]?
    var retrySucceeded: Bool?
    var readinessIssue: String?
    var layoutScreen: LayoutScreen?
    var appearance: String?
    var settingsRecords: [String] = []
}
struct Run: Codable {
    var commit: String
    var dirty: Bool
    var appVersion: String
    var macOS: String
    var appearance: String?
    var displayScale: Double
    var cases: [RunCase]
}
func shell(_ executable: String, _ args: [String], in directory: URL? = nil) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SnapshotError("\(executable) failed (\(process.terminationStatus))")
    }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func pageFile(_ i: Int) -> String { String(format: "page-%04d.png", i + 1) }
func visualName(_ item: SnapshotCase, scale: Double?) -> String {
    if item.kind == .document { return item.id + ".pdf" }
    return "\(item.id)@\(scale.map { String(format:"%g",$0) } ?? "unknown")x.png"
}

struct Capabilities {
    let source: String
    let themes: Set<String>
    let formats: String?
    let captureCode: String
    let settings: String
    let actualScale: Bool
    let recordsStability: Bool
    let opaqueUI: Bool
    init(at root: URL) throws {
        let app = root.appendingPathComponent("App")
        guard let files = fm.enumerator(at: app, includingPropertiesForKeys: nil) else {
            throw SnapshotError("Missing App sources")
        }
        var code = ""
        for case let url as URL in files where url.pathExtension == "swift" {
            code += try String(contentsOf: url, encoding: .utf8) + "\n"
        }
        source = code
        captureCode =
            (try? String(contentsOf: app.appendingPathComponent("DebugSnapshot.swift"), encoding: .utf8)) ?? code
        let kit = root.appendingPathComponent("Packages/SurimonoKit/Sources")
        formats =
            ["SurimonoFormats", "SurimonoCore"].compactMap {
                try? String(contentsOf: kit.appendingPathComponent($0 + "/DocumentFormat.swift"), encoding: .utf8)
            }.first
        recordsStability = code.contains("snapshot-capability: capture-stability")
        opaqueUI = code.contains("snapshot-capability: opaque-ui")
        actualScale = code.contains("snapshot-capability: capture-dpi")
        settings =
            (try? String(contentsOf: app.appendingPathComponent("SettingsCatalogue.swift"), encoding: .utf8)) ?? code
        struct Catalog: Decodable {
            struct Theme: Decodable { let id: String }
            let themes: [Theme]
        }
        let catalog = root.appendingPathComponent("Packages/SurimonoKit/Sources/SurimonoCore/Resources/themes.json")
        themes = Set((try? read(Catalog.self, catalog).themes.map(\.id)) ?? [])
    }

    func missing(_ item: SnapshotCase) -> String? {
        let action = item.kind == .ui ? "SurimonoSnapshotPath" : "SurimonoExportPath"
        for arg in [action, "SurimonoHidePrinters", "SurimonoSnapshotQuit"]
            + item.arguments.filter({ $0.hasPrefix("-Surimono") }).map({ String($0.dropFirst()) })
        {
            if !source.contains("\"\(arg)\"") { return arg }
        }
        if let input = item.input, let formats,
            !formats.contains("\"" + URL(fileURLWithPath: input).pathExtension.lowercased() + "\"")
        {
            return "input format for " + input
        }
        for i in stride(from: 0, to: item.arguments.count, by: 2) {
            let value = item.arguments[i + 1]
            switch item.arguments[i] {
            case "-SurimonoMode", "-SurimonoMenu", "-SurimonoPopover":
                if !captureCode.contains("\"" + value + "\"") { return item.arguments[i] + " " + value }
            case "-theme" where !themes.contains(value): return "theme \(value)"
            case "-SurimonoSettings" where !settings.contains("case \(value) "): return "settings \(value)"
            case "-SurimonoTypeface"
            where item.kind == .document && !source.contains("snapshot-capability: reading-typeface"):
                return "typeface in reading export"
            case "-SurimonoSnapshotWelcome" where !source.contains("snapshot-capability: empty-welcome"):
                return "isolated welcome history"
            default: break
            }
        }
        return nil
    }
}

final class Interrupt: @unchecked Sendable {
    // The dispatch signal handler and the synchronous launch loop share only this locked flag.
    private let lock = NSLock()
    private var stopped = false
    private var sources: [DispatchSourceSignal] = []
    var cancelled: Bool { lock.withLock { stopped } }
    init() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            sources.append(source)
            source.resume()
        }
    }
    private func stop() { lock.withLock { stopped = true } }
}

private enum CaptureFailure: Error { case cannotStop(Int32) }

// Only deadline failures get a second attempt; capture and decode errors keep their own cause.
func retryTimeout(entry: inout RunCase, attempt: (Int) throws -> Void) throws {
    for index in 1...2 {
        do {
            try attempt(index)
            if index == 2 { entry.retrySucceeded = true }
            return
        } catch let timeout as AttemptTimeout {
            entry.timeouts = index
            entry.timeoutDetails = (entry.timeoutDetails ?? []) + [timeout.record]
            entry.retrySucceeded = false
            if index == 2 { throw SnapshotError(timeout.reason) }
        }
    }
}

private func sampleProcess(_ pid: Int32, to file: URL) -> String? {
    let sampler = Process()
    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sampler.arguments = [String(pid), "2", "-file", file.path]
    let messages = Pipe()
    sampler.standardError = messages
    do {
        try sampler.run()
        let deadline = ContinuousClock.now + .seconds(8)
        while sampler.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if sampler.isRunning { _ = kill(sampler.processIdentifier, SIGKILL) }
        sampler.waitUntilExit()
        guard sampler.terminationStatus == 0, fm.fileExists(atPath: file.path) else {
            let log = messages.fileHandleForReading.readDataToEndOfFile()
            let reason = String(decoding: log.prefix(2048), as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return "sample exited \(sampler.terminationStatus): \(reason)"
        }
        return nil
    } catch { return String(describing: error) }
}

@MainActor
private func launch(
    app: URL, input: URL?, args: [String], home: URL, background: Bool, interrupt: Interrupt,
    limit: Int, sampleFile: URL, readiness: URL
) throws {
    let token = UUID().uuidString
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var options = background ? ["-g"] : []
    options += ["-n", "-W", "-a", app.path, "--env", "CFFIXED_USER_HOME=\(home.path)", "--env", "HOME=\(home.path)"]
    options += ["--env", "SURIMONO_SNAPSHOT_STATE=\(readiness.path)"]
    if let input { options.append(input.path) }
    options += [
        "--args", "-SurimonoRunToken", token, "-ApplePersistenceIgnoreState", "YES", "-SurimonoHidePrinters", "YES",
        "-SurimonoSnapshotQuit", "YES", "-NSRecentDocumentsLimit", "0", "-AppleLanguages", "(ja)",
    ]
    open.arguments = options + args
    try open.run()
    let deadline = ContinuousClock.now + .seconds(limit)
    func state() -> String? { try? String(contentsOf: readiness, encoding: .utf8) }
    while open.isRunning && !interrupt.cancelled && ContinuousClock.now < deadline {
        if state()?.hasPrefix("deadline: ") == true { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if open.isRunning {
        defer {
            if open.isRunning { _ = kill(open.processIdentifier, SIGKILL) }
            open.waitUntilExit()
        }
        // LaunchServices parents the app. Match this attempt's token, Debug identity and exact bundle before sampling.
        let list = try shell("/bin/ps", ["-axww", "-o", "pid=,command="])
        let lastState = state()
        var diagnostic: String? = "No live app PID matched this launch token and Debug bundle"
        var sampled: String?
        for row in list.split(separator: "\n") where (row + " ").contains("-SurimonoRunToken \(token) ") {
            guard let field = row.split(whereSeparator: \.isWhitespace).first, let pid = Int32(field),
                let running = NSRunningApplication(processIdentifier: pid),
                running.bundleIdentifier == debugDomain,
                running.bundleURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
            else { continue }
            if !interrupt.cancelled {
                diagnostic = sampleProcess(pid, to: sampleFile)
                if fm.fileExists(atPath: sampleFile.path) { sampled = sampleFile.lastPathComponent }
            }
            _ = running.forceTerminate()
            for _ in 0..<50 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(pid, 0) != 0 && errno == ESRCH else { throw CaptureFailure.cannotStop(pid) }
        }
        if interrupt.cancelled { throw SnapshotError("Interrupted") }
        let record = TimeoutRecord(readiness: lastState, sample: sampled, diagnostic: diagnostic)
        let reason = lastState?.hasPrefix("deadline: ") == true ? lastState : nil
        throw AttemptTimeout(record: record, reason: reason ?? "Timed out after \(limit) seconds")
    }
    if let last = state(), last.hasPrefix("deadline: ") {
        throw AttemptTimeout(
            record: TimeoutRecord(readiness: last, sample: nil, diagnostic: "App exited before sampling"), reason: last)
    }
    if let issue = state(), issue.hasPrefix("issue: ") { throw SnapshotError(issue) }
    guard open.terminationStatus == 0 else { throw SnapshotError("open exited \(open.terminationStatus)") }
}

@MainActor
func capture(root: URL, app: URL, directory: URL, cases: [SnapshotCase], source: URL, historical: Bool) throws -> Run {
    guard let bundle = Bundle(url: app), bundle.executableURL != nil,
        historical || bundle.bundleIdentifier == debugDomain
    else {
        throw SnapshotError("Expected a Debug app with bundle ID \(debugDomain) at \(app.path)")
    }
    let capabilities = try Capabilities(at: source)
    let screens = NSScreen.screens.map(\.backingScaleFactor)
    guard let primary = screens.first else { throw SnapshotError("A logged-in graphical session is required") }
    var run = Run(
        commit: try shell("/usr/bin/git", ["rev-parse", "HEAD"], in: source),
        dirty: try !shell("/usr/bin/git", ["status", "--porcelain"], in: source).isEmpty,
        appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        appearance: NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "dark" : "light",
        displayScale: primary, cases: [])
    guard bundle.bundleIdentifier == debugDomain else {
        // Old builds without an isolated Dev identity must never be launched.
        run.cases = cases.map { RunCase(item: $0, unavailable: "Not available at this ref: no separate Debug bundle") }
        return run
    }
    let interrupt = Interrupt()
    let recentKey = "recentFiles" as CFString
    let domain = debugDomain as CFString
    CFPreferencesAppSynchronize(domain)
    let recent = CFPreferencesCopyValue(recentKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    defer {
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyValue(recentKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if !((recent == nil && current == nil) || (recent != nil && current != nil && CFEqual(recent, current))) {
            CFPreferencesSetValue(recentKey, recent, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesAppSynchronize(domain)
        }
    }
    for item in cases {
        if interrupt.cancelled { throw SnapshotError("Interrupted") }
        var entry = RunCase(item: item)
        if historical, let missing = capabilities.missing(item) {
            entry.unavailable = "Not available at this ref: \(missing)"
        } else if historical && item.kind == .ui && !capabilities.actualScale && Set(screens).count > 1 {
            entry.unavailable = "Historical capture does not record the scale on a mixed-DPI desktop"
        } else {
            let out = directory.appendingPathComponent(item.id)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let home = fm.temporaryDirectory.appendingPathComponent("surimono-snapshot-" + UUID().uuidString)
            defer { try? fm.removeItem(at: home) }
            do {
                let input = item.input.map { root.appendingPathComponent($0) }
                if let input, !fm.fileExists(atPath: input.path) {
                    throw SnapshotError("Missing input \(input.lastPathComponent)")
                }
                let ui = item.kind == .ui
                let file = out.appendingPathComponent(ui ? "window.png" : "document.pdf")
                let outputArgs =
                    ui
                    ? ["-SurimonoSnapshotPath", file.path]
                    : ["-SurimonoExport", "reading", "-SurimonoExportPath", file.path]
                var presentation = item.arguments
                if ui && capabilities.opaqueUI {
                    // Request neutral native colors in this process without changing the system appearance preference.
                    presentation += ["-AppleReduceDesktopTinting", "YES"]
                }
                if ui && !presentation.contains("-SurimonoIncreaseContrast") {
                    presentation += ["-SurimonoIncreaseContrast", "NO"]
                }
                // Background captures must leave the foreground application to the reader.
                let limit = ui ? 60 : 180
                var settingsRecords: [String] = []
                var readinessIssue: String?
                var layoutScreen: LayoutScreen?
                var appearance: String?
                defer {
                    entry.settingsRecords = Array(Set(settingsRecords)).sorted()
                    entry.readinessIssue = readinessIssue
                    entry.layoutScreen = layoutScreen
                    entry.appearance = appearance
                }
                try retryTimeout(entry: &entry) { attempt in
                    if interrupt.cancelled { throw SnapshotError("Interrupted") }
                    let isolated = home.appendingPathComponent("attempt-" + String(attempt))
                    try fm.createDirectory(at: isolated, withIntermediateDirectories: true)
                    let state = isolated.appendingPathComponent("readiness.txt")
                    defer {
                        if let last = try? String(contentsOf: state, encoding: .utf8),
                            last.hasPrefix("issue: ") || last.hasPrefix("deadline: ")
                        {
                            readinessIssue = last
                        }
                        for folder in ["DocumentSettings", "DocumentLocations"] {
                            let records = isolated.appendingPathComponent(
                                "Library/Application Support/Surimono Dev/" + folder)
                            settingsRecords += ((try? fm.contentsOfDirectory(atPath: records.path)) ?? []).map {
                                folder + "/" + $0
                            }
                        }
                    }
                    // A timeout can occur after writing the image but before quitting. Never reuse that output.
                    if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                    readinessIssue = nil
                    let sample = out.appendingPathComponent(
                        attempt == 1 ? "timeout-sample.txt" : "timeout-sample-2.txt")
                    try launch(
                        app: app, input: input, args: presentation + outputArgs, home: isolated,
                        background: ui && capabilities.recordsStability, interrupt: interrupt, limit: limit,
                        sampleFile: sample, readiness: state)
                    appearance = try? String(
                        contentsOf: isolated.appendingPathComponent("appearance.txt"), encoding: .utf8)
                    layoutScreen = try? read(LayoutScreen.self, isolated.appendingPathComponent("layout-screen.json"))
                }
                if ui {
                    _ = try Imaging.load(file)
                    if capabilities.actualScale {
                        guard let image = CGImageSourceCreateWithURL(file as CFURL, nil),
                            let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                            let dpi = props[kCGImagePropertyDPIWidth as String] as? Double, dpi > 0
                        else { throw SnapshotError("Missing image DPI") }
                        entry.scale = (dpi / 72 * 100).rounded() / 100
                        if capabilities.recordsStability {
                            entry.capture = try CaptureObservation.read(pngProperties: props)
                            entry.error = entry.capture?.readinessIssue
                        }
                    } else {
                        entry.scale = primary
                    }
                    try fm.moveItem(at: file, to: out.appendingPathComponent(visualName(item, scale: entry.scale)))
                } else {
                    let pdf = try PDFInput(file)
                    let doc = try pdf.document()
                    try write(try encoded(doc), out.appendingPathComponent("document.json"))
                    try write(Data(doc.text.utf8), out.appendingPathComponent("document.txt"))
                    for i in 0..<doc.pageCount {
                        try autoreleasepool { try Imaging.save(pdf.raster(i), out.appendingPathComponent(pageFile(i))) }
                    }
                }
                if entry.timeouts != nil { entry.retrySucceeded = entry.error == nil && entry.capture?.stable != false }
            } catch let fatal as CaptureFailure { throw fatal } catch {
                entry.error = String(describing: error)
                if entry.timeouts != nil { entry.retrySucceeded = false }
            }
        }
        guard NSScreen.screens.first?.backingScaleFactor == primary else {
            throw SnapshotError("Main display scale changed during capture; start a fresh run")
        }
        let outcome =
            entry.capture?.stable == false ? "unstable" : entry.retrySucceeded == true ? "OK after retry" : "OK"
        print("\(item.id)  \(entry.error ?? entry.unavailable ?? outcome)")
        run.cases.append(entry)
        if interrupt.cancelled { throw SnapshotError("Interrupted") }
    }
    return run
}
