import Foundation
import LaTeXCorpusSupport
import SurimonoRendering
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_LATEX_CLASS"] == "1"))
struct LaTeXClassBenchmarks {
    @Test("クラス情報のキャッシュが空のときにデコードを含む入口でメインスレッドが待つ時間を測る")
    @MainActor
    func coldRenderer() throws {
        try #require(Thread.isMainThread)
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let renderer = DocumentRenderer()
        for (label, url) in try LaTeXClassInputs.corpus(includingSnapshots: true)
            + LaTeXClassInputs.generated(in: temporary)
        {
            var source = DocumentSource(data: try Data(contentsOf: url), fileURL: url, format: .latex)
            source.allowedResourceFolders = [url.deletingLastPathComponent()]
            var times: [Double] = []
            for run in 0...5 {
                renderer.clearCache()
                let start = ContinuousClock.now
                let info = renderer.latexClassInfo(for: source)
                let elapsed = (ContinuousClock.now - start).components
                let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                if !label.hasPrefix("Snapshots/") { try #require(info.recognition != nil) }
                if ["uncommon", "depth20"].contains(label) { try #require(info.hasChapters) }
                if label == "loops" { try #require(info.beamerPageSize != nil) }
                if label == "landscape" { try #require(info.pageBox.paperWidth > info.pageBox.paperHeight) }
                if run == 0 {
                    print("RENDERER_WARMUP", label, ms)
                } else {
                    times.append(ms)
                }
            }
            let sorted = times.sorted()
            print("RENDERER", label, "medianMS=\(sorted[2]) maxMS=\(sorted[4]) runsMS=\(times)")
        }
    }
}
