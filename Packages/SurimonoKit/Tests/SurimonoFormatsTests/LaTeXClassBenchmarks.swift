import Foundation
import LaTeXCorpusSupport
import SurimonoFormats
import Synchronization
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_LATEX_CLASS"] == "1"))
struct LaTeXClassBenchmarks {
    private struct Counts: Equatable, Sendable {
        var attempts = 0
        var successes = 0
        var bytes = 0
    }

    @Test("LaTeX の見本と重い前文でメインスレッドがクラス判定を待つ時間を測る")
    @MainActor
    func measure() throws {
        try #require(Thread.isMainThread)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (label, url) in try LaTeXClassInputs.corpus() + LaTeXClassInputs.generated(in: temporary) {
            let data = try Data(contentsOf: url)
            let source = TextDecoding.decode(data).text
            let folder = try ConfinedFile.canonicalPath(url.deletingLastPathComponent())
            var times: [Double] = []
            var reference: Counts?
            for run in 0...5 {
                let counts = Mutex(Counts())
                let read: @Sendable (URL) -> Data? = { file in
                    let bytes: Data?
                    if let path = try? ConfinedFile.canonicalPath(file), path.hasPrefix(folder + "/") {
                        bytes = try? ConfinedFile.read(file, within: folder, maximumSize: 8_000_004)
                    } else {
                        bytes = nil
                    }
                    counts.withLock {
                        $0.attempts += 1
                        if let bytes {
                            $0.successes += 1
                            $0.bytes += bytes.count
                        }
                    }
                    return bytes
                }
                let start = ContinuousClock.now
                let info = LaTeXConverter.documentClassInfo(
                    source, documentURL: url, readFile: read,
                    fileIdentity: { $0.resolvingSymlinksInPath().standardizedFileURL })
                let duration = (ContinuousClock.now - start).components
                let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                if label == "loops" { try #require(info.beamerPageSize != nil) }
                let reads = counts.withLock { $0 }
                if let reference { try #require(reads == reference) }
                reference = reads
                if run == 0 {
                    print("WARMUP", label, ms)
                } else {
                    times.append(ms)
                }
            }
            let reads = try #require(reference)
            let sorted = times.sorted()
            print(
                "BENCH \(label) sourceBytes=\(data.count) reads=\(reads.successes)/\(reads.attempts)"
                    + " readBytes=\(reads.bytes) medianMS=\(sorted[2]) maxMS=\(sorted[4]) runsMS=\(times)")
        }
    }

    @Test("定義の数を変えて前文判定と本文変換の時間を測る")
    @MainActor
    func macroScaling() throws {
        for count in [500, 1000, 2000, 2498] {
            let source = LaTeXClassInputs.macroDocument(count)
            var checks: [Double] = []
            var conversions: [Double] = []
            for run in 0...5 {
                let start = ContinuousClock.now
                let info = LaTeXConverter.documentClassInfo(source)
                let middle = ContinuousClock.now
                let fragment = LaTeXConverter.convert(source)
                let end = ContinuousClock.now
                try #require(info.recognition != nil)
                try #require(fragment.readingIssues.isEmpty)
                try #require(fragment.body.contains(">7</text>"))
                if run > 0 {
                    checks.append(Self.milliseconds(middle - start))
                    conversions.append(Self.milliseconds(end - middle))
                }
            }
            print(
                "SCALING", count, checks.sorted()[2], checks.sorted()[4], conversions.sorted()[2],
                conversions.sorted()[4])
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

}
