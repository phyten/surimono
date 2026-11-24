import CryptoKit
import Foundation
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

    private func texFiles(in directory: URL) throws -> [URL] {
        let walker = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "tex" }.sorted { $0.path < $1.path }
    }

    private func corpus() throws -> [(String, URL)] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let samples = try texFiles(in: root.appendingPathComponent("Samples"))
        let fixtures = try texFiles(in: root.appendingPathComponent("Packages/SurimonoKit/Tests"))
            .filter { $0.pathComponents.contains("Fixtures") }
        return (samples + fixtures).map { (String($0.path.dropFirst(root.path.count + 1)), $0) }
    }

    private func generated(in directory: URL) throws -> [(String, URL)] {
        func write(_ name: String, _ contents: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".tex")
            try Data(contents.utf8).write(to: url)
            return url
        }
        let begin = "\\begin{document}\n"
        let end = "\n\\end{document}\n"
        let article = "\\documentclass{article}\n"
        let short = try write("short", article + begin + "x" + end)
        let large = try write("body", article + begin + String(repeating: "x", count: 5_000_000) + end)
        let macros = try write("macros", article + Self.definitions(2000) + begin + "x" + end)
        for depth in 1...50 {
            let next = depth == 50 ? "" : "\\input{child\(depth + 1)}\n"
            let padding = String(repeating: "x", count: 20_000 - next.utf8.count - 2)
            _ = try write("child\(depth)", "%" + padding + "\n" + next)
        }
        let nested = try write("nested", article + "\\input{child1}\n" + begin + "x" + end)
        let block = #"""
            \setcounter{n}{0}
            \loop\stepcounter{n}\stepcounter{total}\ifnum\value{n}<3 \repeat
            \foreach \i in {a,b,c}{\ifx\same\same\stepcounter{total}\fi}

            """#
        let loops = try write(
            "loops",
            #"\newcounter{n}\newcounter{total}\def\same{x}"# + "\n" + String(repeating: block, count: 100)
                + #"\ifnum\value{total}=600 \documentclass{beamer}\else\documentclass{article}\fi"# + "\n"
                + begin + "x" + end)
        return [("short", short), ("macros", macros), ("nested", nested), ("loops", loops), ("body", large)]
    }

    private static func definitions(_ count: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var text = ""
        for n in 0..<count {
            let name = String([letters[n / 676], letters[n / 26 % 26], letters[n % 26]])
            text += "\\newcommand{\\bench\(name)}{x}\n"
        }
        return text
    }

    @Test("LaTeX の見本と重い前文でメインスレッドがクラス判定を待つ時間を測る")
    @MainActor
    func measure() throws {
        try #require(Thread.isMainThread)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (label, url) in try corpus() + generated(in: temporary) {
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
        for count in [500, 1000, 2000, 4000] {
            let preamble = Self.definitions(count)
            let source = "\\documentclass{article}\n" + preamble + "\\begin{document}\nx\n\\end{document}\n"
            var checks: [Double] = []
            var conversions: [Double] = []
            for run in 0...5 {
                let start = ContinuousClock.now
                let info = LaTeXConverter.documentClassInfo(source)
                let middle = ContinuousClock.now
                let html = LaTeXConverter.convert(source).body
                let end = ContinuousClock.now
                try #require(info.recognition != nil && html.contains("x"))
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

    @Test("同梱の LaTeX 全件の HTML が高速化前のバイト列と一致する")
    func referenceHTML() throws {
        // SHA-256 of the UTF-8 fragment with a fixed font index at 0322c061.
        let digests = [
            "additive.tex": "502796adcc4f3514cb3e6b7d057fe8a8a3537ddfc34e061a819cb4b1589e44a1",
            "handout.tex": "247018f1fd8304f59fa6a5dea84e18b1620ab10b7eafdd0b6dfd010579f06fad",
            "overflow.tex": "da54f24ff3a251b833c48616a8da020e34c9c864e0053d311df2816055547e32",
            "specimen.tex": "17c9076cf2c197f8a5df14a14f922f8abd56a9e4fd7d14b6ab64b22c88180c18",
            "swap.tex": "23094a4fb930fdf762263ede0ade3077392abb342626719043ff3d0e2c1f457c",
            "column-notes.tex": "23b2004d695b1015a1131a14c8ee4ecc624c6c3c084eae28a3705a128bafffcf",
            "conference-links.tex": "8d4e5f0b80983d014d1cf8839122f5e5a5b17c0c278b3718f56f5647e76461a1",
            "math-outlines.tex": "0bf0a9b20bd2b8e3b95f66fec9c1590331eaec7d6119ed6bf74228c2b7536df5",
            "sample.tex": "276b3f71119fe38593da9da5c27e92fb321c5d76e2ba58af8ac21a8ed90b3843",
        ]
        let files = try corpus()
        #expect(Set(files.map { $0.1.lastPathComponent }) == Set(digests.keys))
        for (path, file) in files {
            let source = TextDecoding.decode(try Data(contentsOf: file)).text
            let html = LaTeXConverter.convert(
                source, fontIndex: .init(faces: [:]), documentURL: file, readFile: { try? Data(contentsOf: $0) }
            ).body
            let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == digests[file.lastPathComponent], "\(path)")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

}
