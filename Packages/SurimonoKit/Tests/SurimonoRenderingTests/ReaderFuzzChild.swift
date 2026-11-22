import Darwin
import Foundation
import RobustnessSupport
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

/// The child half of `make robustness` (Benchmarks/robustness.py is the driver). A trap or a stack overflow ends
/// the whole process, so the child writes each input to disk before reading it; when the process dies, the driver
/// finds the input that ended it there, keeps it and starts a new child after it. A reader that runs too long or
/// grows memory without bound is caught by a watchdog thread, which records the input and ends the process, since a
/// thread cannot be stopped from outside.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_ROBUSTNESS_CHILD"] == "1"))
struct ReaderFuzzChild {
    @MainActor
    @Test("指定した形式の入力を順に読み、落ちた・止まらない入力を親へ知らせる")
    func run() async throws {
        let child = try FuzzChild(environment: ProcessInfo.processInfo.environment)
        try await child.run()
    }
}

private struct FuzzCase: Codable {
    var format: String
    var seed: UInt64
    var index: Int
    var name: String
    var fileExtension: String
    var size: Int
    var steps: [String]
    var limitSeconds: Double
}

/// What the watchdog reads and the case loop writes.
private final class WatchedCase: @unchecked Sendable {
    // Guarded by `lock`; the watchdog thread polls it while the reader runs on another thread.
    private let lock = NSLock()
    private var current: (FuzzCase, ContinuousClock.Instant)?

    func start(_ fuzzCase: FuzzCase) {
        lock.lock()
        current = (fuzzCase, .now)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    /// Raises the running case's limit to `limit`, never lowers it. A case already past its limit keeps it, so the
    /// watchdog still reports the reader that overran, even between two of its looks.
    func allow(_ limit: Duration) {
        lock.lock()
        if let (fuzzCase, start) = current, limit.seconds > fuzzCase.limitSeconds,
            (ContinuousClock.now - start).seconds <= fuzzCase.limitSeconds
        {
            var raised = fuzzCase
            raised.limitSeconds = limit.seconds
            current = (raised, start)
        }
        lock.unlock()
    }

    var running: (FuzzCase, Duration)? {
        lock.lock()
        defer { lock.unlock() }
        return current.map { ($0.0, ContinuousClock.now - $0.1) }
    }
}

@MainActor
private struct FuzzChild {
    let directory: URL
    let format: DocumentFormat
    let seed: UInt64
    let start: Int
    let budget: Duration
    let maximumCases: Int
    let includesLong: Bool
    let replay: URL?
    let memoryCeiling: Int
    /// Only the hand-written cases and the regressions, without mutations.
    let fixedOnly: Bool

    init(environment: [String: String]) throws {
        directory = URL(fileURLWithPath: try #require(environment["SURIMONO_ROBUSTNESS_DIR"]), isDirectory: true)
        format = try #require(DocumentFormat(rawValue: environment["SURIMONO_ROBUSTNESS_FORMAT"] ?? ""))
        seed = UInt64(environment["SURIMONO_ROBUSTNESS_SEED"] ?? "") ?? 1
        start = Int(environment["SURIMONO_ROBUSTNESS_START"] ?? "") ?? 0
        budget = .seconds(Double(environment["SURIMONO_ROBUSTNESS_BUDGET"] ?? "") ?? 60)
        maximumCases = Int(environment["SURIMONO_ROBUSTNESS_COUNT"] ?? "") ?? .max
        includesLong = environment["SURIMONO_ROBUSTNESS_LONG"] != "0"
        replay = environment["SURIMONO_ROBUSTNESS_REPLAY"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        memoryCeiling = (Int(environment["SURIMONO_ROBUSTNESS_MEMORY_MB"] ?? "") ?? 4_096) * 1_000_000
        fixedOnly = environment["SURIMONO_ROBUSTNESS_FIXED_ONLY"] == "1"
    }

    private var hostile: [HostileCase] {
        HostileInputs.cases(for: format).filter { includesLong || !$0.isLong }
    }

    func run() async throws {
        // The replay input is read once, here. A file that cannot be read is a setup failure, reported to the driver
        // as such; reading it as empty would report a clean read.
        var replayBytes: [UInt8]?
        if let replay {
            do {
                replayBytes = Array(try Data(contentsOf: replay))
            } catch {
                try Data("{}".utf8).write(to: directory.appendingPathComponent("setup-failure.json"))
                throw error
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory.appendingPathComponent("current"), withIntermediateDirectories: true)
        let watched = WatchedCase()
        startWatchdog(watched)
        let hostile = hostile
        let regressions = RobustnessCorpus.regressions(for: format)
        let seeds =
            RobustnessCorpus.seeds(for: format).compactMap { try? Array(Data(contentsOf: $0)) }
            + hostile.filter { !$0.isLong }.map { $0.bytes() }.filter { $0.count <= 256 * 1024 }
        let began = ContinuousClock.now
        var index = start
        var ran = 0
        var read = 0
        func progress() -> Data { Data("{\"next\":\(index),\"ran\":\(ran),\"read\":\(read)}".utf8) }
        let fixedCount = hostile.count + regressions.count
        while ran < maximumCases, !fixedOnly || index < fixedCount,
            replay == nil ? ContinuousClock.now - began < budget : ran == 0
        {
            let (fuzzCase, bytes) = make(
                index: index, hostile: hostile, regressions: regressions, seeds: seeds, replayBytes: replayBytes)
            let url = try record(fuzzCase, bytes: bytes)
            watched.start(fuzzCase)
            let caseStart = ContinuousClock.now
            if await self.read(Data(bytes), url: url, watched: watched) { read += 1 }
            watched.finish()
            let elapsed = ContinuousClock.now - caseStart
            if elapsed > .seconds(1) {
                append(
                    "slow.jsonl", "{\"index\":\(index),\"name\":\(json(fuzzCase.name)),\"seconds\":\(elapsed.seconds)}")
            }
            index += 1
            ran += 1
            try progress().write(to: directory.appendingPathComponent("progress.json"))
        }
        try progress().write(to: directory.appendingPathComponent("done.json"))
    }

    // MARK: Cases.

    private func make(
        index: Int, hostile: [HostileCase], regressions: [URL], seeds: [[UInt8]], replayBytes: [UInt8]?
    ) -> (FuzzCase, [UInt8]) {
        func described(_ name: String, _ fileExtension: String, _ bytes: [UInt8], _ steps: [String] = []) -> (
            FuzzCase, [UInt8]
        ) {
            let limit = SmallStack.limit(forBytes: bytes.count)
            return (
                FuzzCase(
                    format: format.rawValue, seed: seed, index: index, name: name, fileExtension: fileExtension,
                    size: bytes.count, steps: steps, limitSeconds: limit.seconds), bytes
            )
        }
        if let replay, let replayBytes {
            return described("replay " + replay.lastPathComponent, replay.pathExtension, replayBytes)
        }
        if index < hostile.count {
            let item = hostile[index]
            return described(item.name, item.fileExtension, item.bytes())
        }
        if index < hostile.count + regressions.count {
            let url = regressions[index - hostile.count]
            return described(
                "regression " + url.lastPathComponent, url.pathExtension, (try? Array(Data(contentsOf: url))) ?? [])
        }
        var random = SeededGenerator(seed: SeededGenerator.caseSeed(seed, format.rawValue, index))
        let base = seeds.randomElement(using: &random) ?? []
        let other = seeds.randomElement(using: &random) ?? []
        let tokens = FormatTokens.tokens(for: format)
        let fileExtension =
            format == .plainText
            ? ["txt", "json", "yaml", "xml", "toml", "jsonl", "log"].randomElement(using: &random) ?? "txt"
            : HostileInputs.defaultExtension(format)
        if format == .docx || format == .zipArchive, Bool.random(using: &random),
            let mutated = Self.mutateMembers(base, tokens: tokens, using: &random)
        {
            return described("member mutation", fileExtension, mutated.0, mutated.1)
        }
        let (bytes, steps) = InputMutator.mutate(base, splice: other, tokens: tokens, using: &random)
        return described("mutation", fileExtension, bytes, steps)
    }

    /// Edits inside an archive's members and re-packs it, since edits of the packed bytes mostly break the archive
    /// before the reader inside it is reached.
    private static func mutateMembers(_ archive: [UInt8], tokens: [String], using random: inout SeededGenerator)
        -> ([UInt8], [String])?
    {
        guard let zip = try? ZipArchive(data: Data(archive)), !zip.entries.isEmpty else { return nil }
        var steps: [String] = []
        var members: [BinaryInputs.ZipMember] = []
        for entry in zip.entries.prefix(64) {
            var bytes = (try? Array(zip.contents(of: entry))) ?? []
            if entry.path.hasSuffix(".xml") || Int.random(in: 0..<4, using: &random) == 0 {
                let mutated = InputMutator.mutate(bytes, splice: [], tokens: tokens, using: &random)
                bytes = mutated.bytes
                steps += mutated.steps.map { "\(entry.path): \($0)" }
            }
            members.append(.init(entry.path, bytes, deflates: Bool.random(using: &random)))
        }
        if Int.random(in: 0..<8, using: &random) == 0, let index = members.indices.randomElement(using: &random) {
            members[index].declaredSize = UInt32.random(in: 0...UInt32.max, using: &random)
            steps.append("\(members[index].name): declared size lies")
        }
        return (BinaryInputs.zip(members), steps)
    }

    private func record(_ fuzzCase: FuzzCase, bytes: [UInt8]) throws -> URL {
        let folder = directory.appendingPathComponent("current", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        // The file is named `self` so that an include of `self` in the input refers to the input itself.
        let url = folder.appendingPathComponent("self").appendingPathExtension(fuzzCase.fileExtension)
        try Data(bytes).write(to: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(fuzzCase).write(to: directory.appendingPathComponent("case.json"))
        return url
    }

    // MARK: Reading, through the app's own entry points.

    private nonisolated static let settings = RenderSettings(
        layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
        preset: HTMLCleanupPreset(id: "none", name: "None"))

    /// Whether the input was read (rather than refused with an error), so a run can tell how much it got through.
    private func read(_ data: Data, url: URL, watched: WatchedCase) async -> Bool {
        let format = format
        switch format {
        case .pdf, .image:
            let prepared = try? await DocumentRenderer().prepare(
                DocumentSource(data: data, fileURL: url, format: format), settings: Self.settings)
            return (prepared?.logicalDocument.pageCount ?? 0) > 0
        case .zipArchive:
            let images: [DocumentSource.Image]? = try? await Self.onSmallStack {
                let archive = try ZipArchive(data: data)
                return try ZipImageSelection(archive: archive).images.prefix(32).enumerated().map { offset, entry in
                    DocumentSource.Image(
                        data: try archive.contents(of: entry),
                        fileURL: URL(fileURLWithPath: "/archive/\(offset).\((entry.path as NSString).pathExtension)"))
                }
            }
            guard let images, !images.isEmpty else { return false }
            let prepared = try? await DocumentRenderer().prepare(.images(images), settings: Self.settings)
            return (prepared?.logicalDocument.pageCount ?? 0) > 0
        default:
            let size = try? await Self.onSmallStack {
                let source = DocumentSource(data: data, fileURL: url, format: format)
                let fragment: HTMLFragment
                if format == .html {
                    fragment = HTMLFragment(body: DocumentRenderer.structureHTML(of: source) ?? "")
                    _ = DocumentOutline.title(ofHTML: try DocumentRenderer.decodedText(data))
                } else {
                    guard let themed = try DocumentRenderer.themedFragment(source) else { return 0 }
                    fragment = themed
                }
                // The passes below are linear in the HTML, which a short input can multiply: a 172 KB formula became
                // 27 MB of SVG text and took 8 s more. Only an output over 32 times its input raises the limit, and
                // only for these passes; the reader itself was held to the input's limit.
                watched.allow(SmallStack.limit(forBytes: fragment.body.utf8.count / 32))
                // What the app derives from the fragment before it reaches WebKit also reads input-shaped HTML.
                let facts = DocumentFacts(fragment: fragment)
                let linked = PaperLinks.endnotes.apply(to: fragment.body, language: "en")
                let html = HTMLDocumentBuilder.build(
                    fragment: HTMLFragment(body: linked, title: fragment.title, latexClass: fragment.latexClass),
                    format: format, theme: Self.settings.theme)
                return facts.headings.count + html.utf8.count
            }
            return (size ?? 0) > 0
        }
    }

    private nonisolated static func onSmallStack<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value)
        async throws -> Value?
    {
        // The watchdog, not this limit, ends a reader that does not finish.
        guard case .finished(let value, _) = try await SmallStack.run(limit: .seconds(86_400), body) else {
            return nil
        }
        return value
    }

    // MARK: Watchdog.

    private func startWatchdog(_ watched: WatchedCase) {
        let directory = directory
        let ceiling = memoryCeiling
        let thread = Thread {
            while true {
                usleep(20_000)
                guard let (fuzzCase, elapsed) = watched.running else { continue }
                let kind: String
                if elapsed > .seconds(fuzzCase.limitSeconds) {
                    kind = "hang"
                } else if SmallStack.peakMemory() > ceiling {
                    kind = "memory"
                } else {
                    continue
                }
                let finding =
                    "{\"kind\":\"\(kind)\",\"index\":\(fuzzCase.index),\"seconds\":\(elapsed.seconds),"
                    + "\"peakMemory\":\(SmallStack.peakMemory())}"
                try? Data(finding.utf8).write(to: directory.appendingPathComponent("finding.json"))
                // The reader's thread cannot be stopped, so the process ends and the driver starts a fresh one.
                _exit(kind == "hang" ? 86 : 87)
            }
        }
        thread.start()
    }

    private func append(_ name: String, _ line: String) {
        let url = directory.appendingPathComponent(name)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data((line + "\n").utf8).write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func json(_ string: String) -> String {
        (try? String(decoding: JSONEncoder().encode(string), as: UTF8.self)) ?? "\"\""
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

struct WatchedCaseTests {
    @Test("読み取りがすでに期限を過ぎていれば、出力の大きさで期限を延ばさない")
    func overrunKeepsItsLimit() async throws {
        let watched = WatchedCase()
        let fuzzCase = FuzzCase(
            format: "rst", seed: 1, index: 0, name: "probe", fileExtension: "rst", size: 1, steps: [],
            limitSeconds: 0.01)
        watched.start(fuzzCase)
        try await Task.sleep(for: .milliseconds(30))
        watched.allow(.seconds(60))
        #expect(watched.running?.0.limitSeconds == 0.01)
        watched.start(fuzzCase)
        watched.allow(.seconds(60))
        #expect(watched.running?.0.limitSeconds == 60)
    }
}
