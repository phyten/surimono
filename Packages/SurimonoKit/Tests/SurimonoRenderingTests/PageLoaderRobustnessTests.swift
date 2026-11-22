import Foundation
import RobustnessSupport
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

/// PDFs, images and ZIPs of images reach PDFKit and ImageIO through `DocumentRenderer.prepare`, as when the app
/// opens them. A damaged file must end in an error for that document, within its time.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PageLoaderRobustnessTests {
    private static let settings = RenderSettings(
        layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
        preset: HTMLCleanupPreset(id: "none", name: "None"))

    private static func prepare(_ source: DocumentSource, bytes: Int) async throws -> Bool {
        let outcome = try await SmallStack.withDeadline(limit: SmallStack.limit(forBytes: bytes)) { @MainActor in
            (try? await DocumentRenderer().prepare(source, settings: settings))?.logicalDocument.pageCount ?? 0
        }
        if case .finished = outcome { return true }
        return false
    }

    @Test("壊れた・極端な PDF と画像を開いても、落ちず時間内にページかエラーになる", arguments: [DocumentFormat.pdf, .image])
    func hostileFiles(_ format: DocumentFormat) async throws {
        for item in HostileInputs.cases(for: format) where !item.isLong {
            let bytes = HostileInputs.$quick.withValue(true) { item.bytes() }
            let source = DocumentSource(
                data: Data(bytes), fileURL: URL(fileURLWithPath: "/robustness/self.\(item.fileExtension)"),
                format: format)
            if try await !Self.prepare(source, bytes: bytes.count) { Issue.record("\(item) did not finish in time") }
        }
    }

    @Test("壊れた・偽った ZIP の画像を束として開いても、落ちず時間内にページかエラーになる")
    func hostileArchives() async throws {
        for item in HostileInputs.cases(for: .zipArchive) where !item.isLong {
            let bytes = HostileInputs.$quick.withValue(true) { item.bytes() }
            guard let archive = try? ZipArchive(data: Data(bytes)) else { continue }
            let images = ZipImageSelection(archive: archive).images.prefix(16).enumerated().compactMap {
                offset, entry -> DocumentSource.Image? in
                guard let data = try? archive.contents(of: entry) else { return nil }
                return DocumentSource.Image(data: data, fileURL: URL(fileURLWithPath: "/archive/\(offset).png"))
            }
            guard !images.isEmpty else { continue }
            if try await !Self.prepare(.images(images), bytes: bytes.count) {
                Issue.record("\(item) did not finish in time")
            }
        }
    }

    @Test("読み取りを落とした・止めた PDF と画像を、落ちず時間内に開ける")
    func regressions() async throws {
        for format in [DocumentFormat.pdf, .image] {
            for url in RobustnessCorpus.regressions(for: format) {
                let data = try Data(contentsOf: url)
                let source = DocumentSource(data: data, fileURL: url, format: format)
                if try await !Self.prepare(source, bytes: data.count) {
                    Issue.record("\(url.lastPathComponent) did not finish in time")
                }
            }
        }
    }
}

@MainActor
struct NestingLimitIssueTests {
    @Test("入れ子が深すぎて文字のまま残した Markdown は、印刷前の確認に入れ子の上限として出る", .timeLimit(.minutes(1)))
    func reportsNestingLimit() async throws {
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let source = DocumentSource(
            data: Data((String(repeating: "> ", count: 5_000) + "deep\n\nAfter.\n").utf8), format: .markdown)
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let result = try await renderer.render(source, settings: settings)
        #expect(result.issues.map(\.kind) == [.nestingLimit])
    }

    @Test("入れ子が深すぎて省いた Notebook の部分は、印刷前の確認に省いた部分として出る", .timeLimit(.minutes(1)))
    func reportsOmission() async throws {
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let text =
            #"{"nbformat":4,"metadata":"# + String(repeating: #"{"a":"#, count: 500) + "1"
            + String(repeating: "}", count: 500)
            + #","cells":[{"cell_type":"markdown","metadata":{},"source":["Kept"]}]}"#
        let source = DocumentSource(data: Data(text.utf8), format: .notebook)
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let result = try await renderer.render(source, settings: settings)
        #expect(result.issues.map(\.kind) == [.nestingOmission])
    }
}
