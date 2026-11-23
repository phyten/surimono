import AppKit
import Darwin
import ImageIO
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH"] == "1"), .serialized)
@MainActor
struct RenderingBenchmarks {
    @Test("描画の時間とメモリを基準値として記録する", .timeLimit(.minutes(60)))
    func record() async throws {
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let runs = try #require(Int(environment["SURIMONO_BENCH_RUNS"] ?? "5"))
        try #require(runs > 0)
        let themes = try PrintThemeLibrary.load()
        let standard = try #require(themes.first { $0.id == "standard" })
        let settings = RenderSettings(
            layout: .a4Single, theme: standard, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let recorder = BenchmarkRecorder(runs: runs)
        let root = BenchmarkRecorder.root
        func sample(_ name: String, _ format: DocumentFormat) throws -> DocumentSource {
            let url = root.appendingPathComponent("Samples/\(name)")
            return DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: format)
        }
        let booklet = try sample("booklet-demo.md", .markdown)
        var sources: [(String, DocumentSource)] = [
            ("markdown-short", try sample("sample.md", .markdown)),
            ("markdown-booklet", booklet),
            ("org", try sample("sample.org", .org)),
            ("html", try sample("sample.html", .html)),
            ("csv", try sample("sample.csv", .csv)),
        ]
        let longMarkdown = (1...200).map {
            "# Page \($0)\n\n" + String(repeating: "Rendering benchmark paragraph. 日本語の段落です。\n\n", count: 8)
        }.joined(separator: "\n<div style=\"break-before: page\"></div>\n\n")
        sources.append(("markdown-200", DocumentSource(data: Data(longMarkdown.utf8), format: .markdown)))
        sources.append(
            (
                "latex",
                DocumentSource(
                    data: Data(
                        #"\documentclass{article}\begin{document}\section{Example}Hello $x^2+y^2=z^2$.\end{document}"#
                            .utf8), format: .latex)
            ))
        let pdf = try RenderingFixtures.pdf(count: 50)
        sources.append(("pdf-50", DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf)))
        let images = try (0..<20).map { index in
            DocumentSource.Image(
                data: try Self.image(index: index),
                fileURL: root.appendingPathComponent("build/bench/image-\(index).tiff"))
        }
        sources.append(("images-20", .images(images)))
        for (name, source) in sources {
            try await recorder.measure("prepare/\(name)") {
                let result = try await DocumentRenderer().prepare(source, settings: settings)
                return result.logicalDocument.pageCount
            }
        }
        let prepared = try await DocumentRenderer().prepare(booklet, settings: settings)
        for (name, layout) in [
            ("a4Single", PrintLayout.a4Single), ("a4Duplex", .a4Duplex),
            ("a3BookletA4", .a3BookletA4), ("a3TwoUp", .a3TwoUp),
        ] {
            try await recorder.measure("compose/\(name)") {
                try await PDFComposer().compose(prepared.logicalDocument, layout: layout, options: settings.options)
                    .pageCount
            }
        }
        let trialThemes = Array(themes.filter { $0.id != standard.id }.prefix(10))
        try #require(trialThemes.count == 10)
        for theme in trialThemes {
            var trial = settings
            trial.theme = theme
            let renderer = DocumentRenderer()
            try await recorder.measure(
                "switch/\(theme.id)",
                setup: {
                    renderer.clearCache()
                    _ = try await renderer.prepare(booklet, settings: settings)
                },
                operation: {
                    try await renderer.prepare(booklet, settings: trial).logicalDocument.pageCount
                })
        }
        // A new sampler for each pass prevents a cache hit from masquerading as a drawing measurement.
        for pass in 0...runs {
            print("BENCH sample/all pass=\(pass)/\(runs)")
            let sampler = try #require(try DocumentRenderer.themeSampler(for: booklet, settings: settings))
            defer { sampler.close() }
            let batch = try await BenchmarkRecorder.capture {
                for theme in themes {
                    let measurement = try await BenchmarkRecorder.capture {
                        _ = try await sampler.firstPage(for: theme)
                        return 1
                    }
                    if pass > 0 { recorder.append("sample/\(theme.id)", measurement) }
                }
                return sampler.drawCount
            }
            if pass > 0 { recorder.append("sample/all", batch) }
        }
        for pass in 0...runs {
            print("BENCH endurance pass=\(pass)/\(runs)")
            let renderer = DocumentRenderer()
            _ = try await renderer.prepare(booklet, settings: settings)
            var checkpoints: [BenchmarkCheckpoint] = []
            let measurement = try await BenchmarkRecorder.capture {
                checkpoints.append(BenchmarkCheckpoint(iteration: 0, bytes: try BenchmarkRecorder.footprint()))
                for index in 0..<100 {
                    var trial = settings
                    trial.theme = trialThemes[index % trialThemes.count]
                    _ = try await renderer.prepare(booklet, settings: trial)
                    if (index + 1).isMultiple(of: 10) {
                        checkpoints.append(
                            BenchmarkCheckpoint(iteration: index + 1, bytes: try BenchmarkRecorder.footprint()))
                    }
                }
                return 100
            }
            if pass > 0 {
                recorder.append("endurance/100-switches", measurement)
                recorder.endurance.append(checkpoints)
            }
        }
        try recorder.write(environment: environment)
    }

    @Test("計測の集計とJSONに全測定回を残す", .timeLimit(.minutes(1)))
    func recordsSummary() async throws {
        let recorder = BenchmarkRecorder(runs: 4)
        for time in [9.0, 1.0, 5.0, 3.0] {
            recorder.append(
                "fixture",
                BenchmarkMeasurement(
                    milliseconds: time, beforeBytes: 100, afterBytes: 120, peakBytes: 150, outputCount: 2))
        }
        var calls = 0
        try await recorder.measure("warmup") {
            calls += 1
            return calls
        }
        #expect(recorder.results["warmup"]?.map(\.outputCount) == [2, 3, 4, 5])
        for time in [7.0, 1.0, 5.0] {
            recorder.append(
                "odd",
                BenchmarkMeasurement(
                    milliseconds: time, beforeBytes: 100, afterBytes: 120, peakBytes: 150, outputCount: 2))
        }
        #expect(recorder.summarizedResults.first { $0.id == "odd" }?.medianMS == 5)
        let data = try JSONEncoder().encode(recorder.summarizedResults)
        let results = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let result = try #require(results.first)
        #expect(result["medianMS"] as? Double == 4)
        #expect(result["minMS"] as? Double == 1)
        #expect(result["maxMS"] as? Double == 9)
        let measurements = try #require(result["measurements"] as? [[String: Any]])
        #expect(measurements.count == 4)
        #expect(measurements.first?["peakBytes"] as? Int == 150)
        let captured = try await BenchmarkRecorder.capture { 2 }
        #expect(captured.outputCount == 2)
        #expect(captured.peakBytes >= captured.beforeBytes)
        #expect(captured.peakBytes >= captured.afterBytes)
    }

    fileprivate static func image(index: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 1024, height: 768, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: CGFloat(index) / 20, green: 0.3, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_PAGES"] == "1"), .serialized)
@MainActor
struct PageThumbnailBenchmarks {
    @Test("四種類の論理ページから未キャッシュの縮図を描く時間とメモリを測る")
    func raster() async throws {
        let root = BenchmarkRecorder.root
        let settings = RenderSettings(
            layout: .a4Single, theme: try #require(PrintThemeLibrary.load().first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let environment = ProcessInfo.processInfo.environment
        let captures = environment["SURIMONO_BENCH_READING_PDFS"].map { URL(fileURLWithPath: $0) }
        func source(path: String, format: DocumentFormat, capture: String) throws -> DocumentSource {
            let url = captures?.appendingPathComponent(capture + ".pdf") ?? root.appendingPathComponent(path)
            return DocumentSource(
                data: try Data(contentsOf: url), fileURL: url, format: captures == nil ? format : .pdf)
        }
        let name = try #require(environment["SURIMONO_BENCH_PAGE_INPUT"])
        let input: DocumentSource
        switch name {
        case "booklet":
            input = try source(path: "Samples/booklet-demo.md", format: .markdown, capture: "sample-booklet-demo-md")
        case "deck":
            input = try source(
                path: "Snapshots/corpus/latex/083-class-beamer/main.tex", format: .latex, capture: "latex-083")
        case "pdf-300", "pdf-2000":
            let document = try RenderingFixtures.pdf(
                count: name == "pdf-300" ? 300 : 2000, textPrefix: "Index of workshop drawings. Sheet ")
            input = DocumentSource(data: try #require(document.dataRepresentation()), format: .pdf)
        case "images-20":
            input = .images(
                try (0..<20).map { i in
                    DocumentSource.Image(
                        data: try RenderingBenchmarks.image(index: i),
                        fileURL: root.appendingPathComponent("build/bench/image-\(i).tiff"))
                })
        default:
            Issue.record("Unknown page benchmark input: \(name)")
            return
        }
        let render = try await DocumentRenderer().prepare(input, settings: settings)
        let count = render.viewDocument.pageCount
        #if DEBUG
            if environment["SURIMONO_BENCH_SCRUB"] == "1" {
                try await sweep(render, name: name)
                return
            }
        #endif
        do {
            let cache = PageThumbnails(render)
            let memory = try await BenchmarkRecorder.capture {
                for index in 0..<count { _ = try #require(await cache.image(page: index, pixels: 320)) }
                return count
            }
            let delta = Int64(memory.afterBytes) - Int64(memory.beforeBytes)
            let peak = memory.peakBytes - memory.beforeBytes
            print("PAGES memory \(name) footprintDelta=\(delta) peakDelta=\(peak) bitmapBytes=\(await cache.byteCount)")
        }
        for pixels in [160, 320] {
            var first: [Double] = []
            var times: [Double] = []
            for _ in 0..<20 {
                let start = ProcessInfo.processInfo.systemUptime
                let cache = PageThumbnails(render)
                for index in 0..<min(count, 20) {
                    let before = ProcessInfo.processInfo.systemUptime
                    let bitmap = await cache.image(page: index, pixels: pixels)
                    try #require(bitmap != nil)
                    let end = ProcessInfo.processInfo.systemUptime
                    if index == 0 { first.append(1000 * (end - start)) }
                    times.append(1000 * (end - before))
                }
            }
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                values.sorted()[Int(ceil(Double(values.count) * fraction)) - 1]
            }
            print(
                "PAGES \(name) count=\(count) px=\(pixels) first50=\(percentile(first, 0.5)) first95=\(percentile(first, 0.95)) tile50=\(percentile(times, 0.5)) tile95=\(percentile(times, 0.95))"
            )
        }
    }
    #if DEBUG
        /// Measures the request path independently of the hosted window. Captured reading PDFs can substitute
        /// for WebKit in headless environments; the window benchmark measures the installed SwiftUI image.
        private func sweep(_ render: PreparedRender, name: String) async throws {
            let count = render.viewDocument.pageCount
            try #require(count > 1)
            let track = PageTrack(count: count, rightToLeft: false)
            let pixels = 448
            let clock = ProcessInfo.processInfo
            var cold: [Double] = []
            var warm: [Double] = []
            let cache = PageThumbnails(render)
            var longest = 0.0
            var positions = 0
            let memory = try await BenchmarkRecorder.capture {
                var pending: Task<CGImage?, Never>?
                var previousPage: Int?
                let start = clock.systemUptime
                var last = start
                while true {
                    let now = clock.systemUptime
                    longest = max(longest, (now - last) * 1000)
                    last = now
                    let fraction = min(1, now - start)
                    let page = try #require(track.page(at: fraction))
                    if page != previousPage {
                        pending?.cancel()
                        pending = Task { await cache.scrubImage(page: page, pixels: pixels) }
                        previousPage = page
                        positions += 1
                    }
                    if fraction >= 1 { break }
                    try await Task.sleep(for: .milliseconds(4))
                }
                try #require(await pending?.value != nil)
                return positions
            }
            for sample in 0..<24 {
                let cache = PageThumbnails(render)
                let page = try #require(track.page(at: CGFloat(sample) / 23))
                let start = clock.systemUptime
                let first = await cache.scrubImage(page: page, pixels: pixels)
                let shown = clock.systemUptime
                let hit = await cache.scrubImage(page: page, pixels: pixels)
                let end = clock.systemUptime
                try #require(first != nil && hit === first)
                cold.append((shown - start) * 1000)
                warm.append((end - shown) * 1000)
            }
            func p(_ values: [Double], _ fraction: Double) -> Double {
                values.sorted()[Int(ceil(Double(values.count) * fraction)) - 1]
            }
            let delta = Int64(memory.afterBytes) - Int64(memory.beforeBytes)
            print(
                "SCRUB renderer \(name) pages=\(count) px=\(pixels) cold50=\(p(cold, 0.5)) cold95=\(p(cold, 0.95)) warm50=\(p(warm, 0.5)) warm95=\(p(warm, 0.95)) maxMainGapMS=\(longest) requests=\(positions) started=\(await cache.rendersStarted) finished=\(await cache.rendersFinished) footprintDelta=\(delta) peakDelta=\(memory.peakBytes - memory.beforeBytes) bitmapBytes=\(await cache.byteCount)"
            )
        }
    #endif

}

private struct BenchmarkCheckpoint: Codable {
    let iteration: Int
    let bytes: UInt64
}

private struct BenchmarkMeasurement: Codable {
    let milliseconds: Double
    let beforeBytes: UInt64
    let afterBytes: UInt64
    let peakBytes: UInt64
    let outputCount: Int
}

private struct BenchmarkResult: Codable {
    let id: String
    let medianMS: Double
    let minMS: Double
    let maxMS: Double
    let measurements: [BenchmarkMeasurement]
}

@MainActor
private final class BenchmarkRecorder {
    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    let runs: Int
    var results: [String: [BenchmarkMeasurement]] = [:]
    var endurance: [[BenchmarkCheckpoint]] = []

    init(runs: Int) { self.runs = runs }

    func append(_ id: String, _ measurement: BenchmarkMeasurement) {
        results[id, default: []].append(measurement)
    }

    func measure(
        _ id: String, setup: () async throws -> Void = {}, operation: () async throws -> Int
    ) async throws {
        print("BENCH \(id)")
        for pass in 0...runs {
            try await setup()
            let measurement = try await Self.capture(operation)
            if pass > 0 { append(id, measurement) }
        }
    }

    static func capture(_ operation: () async throws -> Int) async throws -> BenchmarkMeasurement {
        let before = try footprint()
        // Sampling off the main actor also observes allocations during synchronous PDF and WebKit work.
        let monitor = Task.detached {
            var peak = before
            while !Task.isCancelled {
                peak = max(peak, try footprint())
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
            return peak
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let count = try await operation()
            let duration = start.duration(to: clock.now).components
            let after = try footprint()
            monitor.cancel()
            let peak = try await monitor.value
            return BenchmarkMeasurement(
                milliseconds: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15,
                beforeBytes: before, afterBytes: after, peakBytes: max(before, after, peak), outputCount: count)
        } catch {
            monitor.cancel()
            _ = try? await monitor.value
            throw error
        }
    }

    nonisolated static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: "task_info", code: Int(status)) }
        return info.phys_footprint
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = Self.root
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: executable, code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var summarizedResults: [BenchmarkResult] {
        results.keys.sorted().map { id in
            let values = results[id]!
            let times = values.map(\.milliseconds).sorted()
            let middle = times.count / 2
            let median = times.count.isMultiple(of: 2) ? (times[middle - 1] + times[middle]) / 2 : times[middle]
            return BenchmarkResult(
                id: id, medianMS: median, minMS: times.first!, maxMS: times.last!, measurements: values)
        }
    }

    func write(environment: [String: String]) throws {
        struct Report: Codable {
            let schemaVersion: Int
            let date: String
            let commit: String
            let dirty: Bool
            let macOS: String
            let xcode: String
            let model: String
            let cpuCount: Int
            let runs: Int
            let configuration: String
            let memorySampleIntervalMS: Int
            let results: [BenchmarkResult]
            let endurance: [[BenchmarkCheckpoint]]
        }
        let commit = try command("/usr/bin/git", ["rev-parse", "HEAD"])
        let date = ISO8601DateFormatter().string(from: Date())
        let sorted = summarizedResults
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        let report = Report(
            schemaVersion: 1, date: date, commit: commit,
            dirty: try !command("/usr/bin/git", ["status", "--porcelain"]).isEmpty,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            xcode: try command("/usr/bin/xcodebuild", ["-version"]),
            model: try command("/usr/sbin/sysctl", ["-n", "hw.model"]),
            cpuCount: ProcessInfo.processInfo.processorCount, runs: runs, configuration: configuration,
            memorySampleIntervalMS: 10, results: sorted, endurance: endurance)
        let path =
            environment["SURIMONO_BENCH_OUT"]
            ?? "build/bench/\(date.replacingOccurrences(of: ":", with: "-"))-\(commit.prefix(8)).json"
        let url = URL(fileURLWithPath: path, relativeTo: Self.root).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        print("scenario | median ms | min ms | max ms | before MiB | after MiB | peak MiB")
        for result in sorted {
            let last = result.measurements.last!
            let peak = result.measurements.map(\.peakBytes).max()!
            print(
                String(
                    format: "%@ | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f", result.id,
                    result.medianMS, result.minMS, result.maxMS, Double(last.beforeBytes) / 1_048_576,
                    Double(last.afterBytes) / 1_048_576, Double(peak) / 1_048_576))
        }
        print("Benchmark JSON: \(url.path)")
    }
}
