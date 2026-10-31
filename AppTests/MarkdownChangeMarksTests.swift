import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MarkdownChangeMarksTests {
    @MainActor private final class Probe {
        var calls = 0
        var fails = false

        func paginate(_ request: PaginationRequest) throws -> PDFDocument {
            calls += 1
            if fails { throw WebPaginator.PaginationError.printFailed }
            let document = try #require(PDFDocument(data: TestFixtures.pdf("Preview", pages: 3)))
            if case .html(let html, _) = request.source, request.preparationScript?.contains("surimono-mark:") == true {
                let regex = try NSRegularExpression(pattern: #"data-surimono-block="([^"]+)""#)
                for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let range = try #require(Range(match.range(at: 1), in: html))
                    let anchor = PDFAnnotation(
                        bounds: CGRect(x: 50, y: 100 + calls, width: 1, height: 80), forType: .link, withProperties: nil
                    )
                    anchor.url = URL(string: "surimono-mark:\(html[range])")
                    document.page(at: 0)?.addAnnotation(anchor)
                }
            }
            return document
        }
    }

    @MainActor private struct Fixture {
        let model: DocumentViewModel
        let probe: Probe
        let renderer: DocumentRenderer
        let directory: URL
        let file: URL
        let suite: TestDefaultsSuite

        func close() {
            model.stop()
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(_ text: String) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.md")
        let data = Data(text.utf8)
        try data.write(to: file)
        let suite = TestDefaultsSuite()
        let probe = Probe()
        let renderer = DocumentRenderer(paginate: { try probe.paginate($0) })
        let model = DocumentViewModel(
            data: data, fileURL: file, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: renderer,
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        model.start()
        try await wait { model.result != nil && !model.isRendering }
        return Fixture(model: model, probe: probe, renderer: renderer, directory: directory, file: file, suite: suite)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func reload(_ text: String, _ fixture: Fixture) async throws {
        let previous = fixture.probe.calls
        try Data(text.utf8).write(to: fixture.file, options: .atomic)
        fixture.model.reload()
        try await wait { fixture.probe.calls > previous && !fixture.model.isRendering }
    }

    private actor HeldRead {
        var continuations: [CheckedContinuation<Data, Never>] = []
        var count: Int { continuations.count }
        func read() async -> Data { await withCheckedContinuation { continuations.append($0) } }
        func finish(_ bytes: Data) {
            let pending = continuations
            continuations = []
            for continuation in pending { continuation.resume(returning: bytes) }
        }
    }

    @Test("明示的な再読込中に同じ内容の監視通知が来てもキャッシュを強制更新する")
    func watcherDoesNotDowngradeExplicitReload() async throws {
        let fixture = try await fixture("First")
        defer { fixture.close() }
        let held = HeldRead()
        fixture.model.readReloadData = { _ in await held.read() }
        let old = fixture.model.result?.logicalDocument
        let calls = fixture.probe.calls
        fixture.model.reload()
        while await held.count < 1 { await Task.yield() }
        fixture.model.handleFileEvent(.changed)
        while await held.count < 2 { await Task.yield() }
        await held.finish(Data("First".utf8))
        try await wait { !fixture.model.isRendering }
        #expect(fixture.probe.calls > calls)
        #expect(fixture.model.result?.logicalDocument !== old)
        #expect(fixture.model.canOutput)
    }

    @Test("再読込の待機中に削除されても最後のプレビューを出力できる")
    func removalReleasesReadProgress() async throws {
        let fixture = try await fixture("First")
        defer { fixture.close() }
        let held = HeldRead()
        fixture.model.readReloadData = { _ in await held.read() }
        let old = fixture.model.result?.logicalDocument
        fixture.model.reload()
        while await held.count < 1 { await Task.yield() }
        #expect(fixture.model.isRendering)
        fixture.model.handleFileEvent(.removed)
        #expect(!fixture.model.isRendering)
        #expect(fixture.model.canOutput)
        await held.finish(Data("Late".utf8))
        await Task.yield()
        #expect(fixture.model.result?.logicalDocument === old)
        #expect(fixture.model.markdownChanges.isEmpty)
    }

    @Test("読み込み中に別の描画が始まった場合は削除通知でその進捗を解除しない")
    func removalDoesNotFinishAnotherRender() async throws {
        let fixture = try await fixture("First")
        defer { fixture.close() }
        let read = HeldRead()
        let composition = HeldRead()
        fixture.model.readReloadData = { _ in await read.read() }
        fixture.model.reload()
        while await read.count < 1 { await Task.yield() }
        fixture.renderer.clearCache()
        fixture.renderer.willComposeSheet = { _ = await composition.read() }
        fixture.model.render()
        while await composition.count < 1 { await Task.yield() }
        fixture.model.handleFileEvent(.removed)
        #expect(fixture.model.isRendering)
        await read.finish(Data("Late".utf8))
        await composition.finish(Data())
        try await wait { !fixture.model.isRendering }
        #expect(fixture.model.canOutput)
    }

    @Test("初回は印を出さず次の異なる内容で置き換え同じ内容の明示的再読込は印を保ち再描画する")
    func lifecycle() async throws {
        let fixture = try await fixture("First\n\nSecond")
        defer { fixture.close() }
        let model = fixture.model
        #expect(model.markdownChanges.isEmpty)
        #expect(model.paperChangeMarks.isEmpty)
        try await reload("Edited\n\nSecond", fixture)
        let first = model.markdownChanges
        #expect(first.count == 1)
        #expect(model.paperChangeMarks.count == 1)
        #expect(model.result?.logicalDocument.page(at: 0)?.annotations.isEmpty == true)
        let calls = fixture.probe.calls
        model.reload()
        try await wait { fixture.probe.calls > calls && !model.isRendering }
        #expect(model.markdownChanges == first)
        try await reload("Edited\n\nChanged", fixture)
        #expect(model.markdownChanges.count == 1)
        #expect(model.markdownChanges != first)
        #expect(model.markdownChanges == MarkdownChanges.marks(from: "Edited\n\nSecond", to: "Edited\n\nChanged"))
        model.mode = .print
        #expect(model.paperChangeMarks.isEmpty)
        model.mode = .compare
        #expect(model.paperChangeMarks.isEmpty)
        model.mode = .view
        #expect(model.paperChangeMarks.count == 1)
        let reopened = DocumentViewModel(
            data: Data("Edited\n\nChanged".utf8), fileURL: fixture.file, format: .markdown,
            preferences: model.preferences, library: model.library,
            settingsStore: DocumentSettingsStore(directory: fixture.directory.appendingPathComponent("Settings")))
        #expect(reopened.markdownChanges.isEmpty)
    }

    @Test("テーマと用紙と文字の大きさを変えても同じ変更ブロックの矩形を組み直す")
    func settingsRecomputeGeometry() async throws {
        let fixture = try await fixture("First")
        defer { fixture.close() }
        try await reload("Edited", fixture)
        let model = fixture.model
        let requests = model.markdownChanges
        for change in [0, 1, 2] {
            let old = model.paperChangeMarks
            switch change {
            case 0: model.themeID = "mincho"
            case 1: model.layoutID = "a4BookletA5"
            default: model.setTextScale(1.25)
            }
            model.render()
            try await wait { !model.isRendering }
            #expect(model.markdownChanges == requests)
            #expect(!model.paperChangeMarks.isEmpty)
            #expect(model.paperChangeMarks != old)
        }
    }

    @Test("差分の上限を超えても新しい内容へ再読込し印だけを省く")
    func largeDiffStillReloads() async throws {
        let original = Array(repeating: "line", count: 1001).joined(separator: "\n")
        let fixture = try await fixture(original)
        defer { fixture.close() }
        let changed = "edited\n" + original
        try await reload(changed, fixture)
        try await wait { fixture.model.contentHash == ContentHash.of(Data(changed.utf8)) }
        #expect(fixture.model.markdownChanges.isEmpty)
        #expect(fixture.model.paperChangeMarks.isEmpty)
        #expect(fixture.model.result != nil)
    }

    @Test("描画に失敗した版ではなく最後に表示できた版と差分を取る")
    func comparesDisplayedVersion() async throws {
        let fixture = try await fixture("First\n\nSecond")
        defer { fixture.close() }
        fixture.probe.fails = true
        try await reload("Failed\n\nSecond", fixture)
        fixture.probe.fails = false
        try await reload("First\n\nChanged", fixture)
        #expect(fixture.model.markdownChanges == MarkdownChanges.marks(from: "First\n\nSecond", to: "First\n\nChanged"))
    }
}
