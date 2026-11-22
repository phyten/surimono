import Foundation
import RobustnessSupport
import SurimonoFormats
import Testing

/// The short, fixed slice of `make robustness` for the readers in SurimonoFormats. Every input is read on a 512 KiB
/// thread, as the app reads documents, and must finish within the time its size allows.
// Each input may take three times its limit here, and ten times that under a sanitizer.
@Suite(.timeLimit(.minutes(Sanitizer.isActive ? 30 : 2)))
struct ReaderRobustnessTests {
    static let formats = FormatsReader.formats

    static let regressions: [URL] = formats.flatMap(RobustnessCorpus.regressions(for:))
        .filter { $0.path.contains("/SurimonoFormatsTests/") }

    /// Reads `bytes` as a file named `self.<extension>` in a folder of its own, so that an include of `self`
    /// finds the document again.
    static func read(_ format: DocumentFormat, _ bytes: [UInt8], extension fileExtension: String) async throws
        -> SmallStack.Outcome<Int>
    {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("surimono-robustness-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let url = folder.appendingPathComponent("self").appendingPathExtension(fileExtension)
        let data = Data(bytes)
        try data.write(to: url)
        // Three times the child's limit: here the cases run beside the rest of `make test-kit`, and `make robustness`
        // holds each input to the strict limit in a process of its own.
        return try await SmallStack.run(limit: SmallStack.limit(forBytes: bytes.count) * 3) {
            guard let fragment = try? FormatsReader.read(format, data: data, url: url) else { return 0 }
            return DocumentOutline.headings(inHTML: fragment.body).count + fragment.body.utf8.count
        }
    }

    /// The slice in `make test-kit` reads the cases up to this size; `make robustness` reads all of them.
    static let quickSize = 128_000

    @Test("壊れた・極端な文書を小さなスタックで読んでも、落ちず時間内に終わる", arguments: formats)
    func hostileInputs(_ format: DocumentFormat) async throws {
        for item in HostileInputs.cases(for: format) where !item.isLong {
            let bytes = HostileInputs.$quick.withValue(true) { item.bytes() }
            guard bytes.count <= Self.quickSize else { continue }
            let outcome = try await Self.read(format, bytes, extension: item.fileExtension)
            if case .timedOut = outcome { Issue.record("\(item) did not finish in time") }
        }
    }

    @Test("読み取りを落とした・止めた入力を、落ちず時間内に読める", arguments: regressions)
    func regression(_ url: URL) async throws {
        let format = try #require(DocumentFormat(rawValue: url.deletingLastPathComponent().lastPathComponent))
        let outcome = try await Self.read(format, Array(try Data(contentsOf: url)), extension: url.pathExtension)
        guard case .finished = outcome else {
            Issue.record("\(url.lastPathComponent) did not finish in time")
            return
        }
    }

    @Test("種の文書を決まった乱数で変えて読んでも、落ちず時間内に終わる", arguments: formats)
    func mutations(_ format: DocumentFormat) async throws {
        let seeds =
            RobustnessCorpus.seeds(for: format).prefix(8).compactMap { try? Array(Data(contentsOf: $0)) }
            + [Array(HostileInputs.sample(format).utf8)]
        for index in 0..<24 {
            var random = SeededGenerator(seed: SeededGenerator.caseSeed(2026, format.rawValue, index))
            let base = seeds.randomElement(using: &random) ?? []
            let other = seeds.randomElement(using: &random) ?? []
            let (bytes, steps) = InputMutator.mutate(
                base, splice: other, tokens: FormatTokens.tokens(for: format), using: &random)
            let outcome = try await Self.read(format, bytes, extension: HostileInputs.defaultExtension(format))
            if case .timedOut = outcome { Issue.record("mutation \(index) (\(steps)) did not finish in time") }
        }
    }
}
