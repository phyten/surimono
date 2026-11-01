import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// Holds or fails the sheet composition of a renderer, so a test sees the time between the logical pages and their
/// sheets.
@MainActor
private final class CompositionGate {
    var isHeld = false
    var failure: (any Error)?
    private(set) var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func pass() async throws {
        if let failure {
            self.failure = nil
            throw failure
        }
        guard isHeld else { return }
        waiting += 1
        // Not cancellable on purpose: a superseded render still finishes its composition and must not publish it.
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        isHeld = false
        let held = continuations
        continuations = []
        for continuation in held { continuation.resume() }
    }
}

private struct CompositionFailure: Error {}

@MainActor
struct PrintSheetFlowTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    private func renderedModel(
        _ suite: TestDefaultsSuite, directory: URL, pages: Int = 4, layout: PrintLayout = .a4Single,
        gate: CompositionGate? = nil
    ) async throws -> DocumentViewModel {
        let renderer = DocumentRenderer()
        if let gate { renderer.willComposeSheet = { try await gate.pass() } }
        let model = DocumentViewModel(
            data: TestFixtures.pdf("sheets", pages: pages), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        model.layoutID = layout.id
        model.enterPrintMode()
        model.render()
        try await waitUntil { !model.isRendering }
        return model
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test(
        "表示からの書き出しと印刷は刷り台に入り、印刷レイアウトの用紙ができるまで保留する",
        .timeLimit(.minutes(1)),
        arguments: [DocumentViewModel.Output.exportPDF, .print(quick: false), .print(quick: true)])
    func outputFromViewWaitsForPrintSheets(output: DocumentViewModel.Output) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        defer { gate.release() }
        let model = try await renderedModel(suite, directory: directory, gate: gate)
        defer { model.stop() }
        model.exitPrintMode()
        model.layoutID = PrintLayout.a4BookletA5.id
        #expect(model.canOutput)
        #expect(model.renderedSettings?.layout == .a4Single)

        var outputs: [(DocumentViewModel.Output, RenderResult)] = []
        model.outputOverride = { outputs.append(($0, $1)) }
        switch output {
        case .exportPDF: model.exportPDF()
        case .print(let quick): model.printDocument(quick: quick)
        }
        #expect(model.mode == .print)
        #expect(model.outputAfterReview == output)
        #expect(!model.canOutput)
        #expect(!model.isExporting && !model.isPrinting)
        #expect(outputs.isEmpty)

        gate.isHeld = true
        model.render()
        try await waitUntil { gate.waiting == 1 }
        #expect(model.renderedSettings?.layout == .a4BookletA5)
        #expect(model.outputAfterReview == output)
        #expect(!model.canOutput)
        #expect(outputs.isEmpty)
        gate.release()
        try await waitUntil { !model.isRendering }
        #expect(model.outputAfterReview == nil)
        #expect(model.canOutput)
        #expect(model.printResult?.layout == .a4BookletA5)
        #expect(model.printResult?.sheetDocument.pageCount == 2)
        #expect(!model.isExporting && !model.isPrinting)
        #expect(outputs.count == 1)
        let (executed, result) = try #require(outputs.first)
        #expect(executed == output)
        #expect(result.layout == .a4BookletA5)
        #expect(result.id == model.printResult?.id)
        #expect(result.sheetDocument.pageCount == 2)

        // Another completed render must not execute the consumed request again.
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(outputs.count == 1)
    }

    @Test("表示と印刷の用紙が同じなら組み直さずに出力待ちを終える", .timeLimit(.minutes(1)))
    func matchingLayoutDoesNotWaitForAnotherRender() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = try await renderedModel(suite, directory: directory)
        defer { model.stop() }
        model.exitPrintMode()
        let resultID = model.printResult?.id
        var outputs: [(DocumentViewModel.Output, RenderResult)] = []
        model.outputOverride = { outputs.append(($0, $1)) }
        model.exportPDF()
        #expect(model.mode == .print)
        #expect(model.outputAfterReview == nil)
        #expect(!model.isRendering)
        #expect(model.printResult?.id == resultID)
        #expect(model.canOutput)
        #expect(outputs.count == 1)
        #expect(outputs.first?.0 == .exportPDF)
        #expect(outputs.first?.1.id == resultID)
        #expect(outputs.first?.1.layout == .a4Single)
    }

    @Test("出力を待つ間に表示へ戻ったら、その出力を取り消す", .timeLimit(.minutes(1)))
    func leavingTrayCancelsPendingOutput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = try await renderedModel(suite, directory: directory)
        defer { model.stop() }
        model.exitPrintMode()
        model.layoutID = PrintLayout.a4BookletA5.id
        model.exportPDF()
        #expect(model.outputAfterReview == .exportPDF)
        model.exitPrintMode()
        #expect(model.mode == .view)
        #expect(model.outputAfterReview == nil)
        #expect(model.renderSettings?.layout == .a4Single)
    }

    @Test("論理ページを出してから用紙ができるまでは、刷り台にも出力にも前の用紙を使わない", .timeLimit(.minutes(1)))
    func logicalPagesBeforeSheets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        defer { gate.release() }
        let model = try await renderedModel(suite, directory: directory, gate: gate)
        defer { model.stop() }
        let old = try #require(model.printResult)
        #expect(model.hasCurrentPrintPreview)

        gate.isHeld = true
        model.printOptions.showsPageNumbers = true
        model.render()
        try await waitUntil { gate.waiting == 1 }
        // The paper already has the new render, with the same logical document; its sheets are not composed yet.
        #expect(model.result?.id != old.id)
        #expect(model.result?.logicalDocument === old.logicalDocument)
        #expect(model.printResult?.id == old.id)
        #expect(!model.hasCurrentPrintPreview)
        #expect(!model.canOutput)
        #expect(FoldSource.current(model) == nil)

        gate.release()
        try await waitUntil { !model.isRendering }
        #expect(model.printResult?.id == model.result?.id)
        #expect(model.printResult?.sheetDocument !== old.sheetDocument)
        #expect(model.hasCurrentPrintPreview)
        #expect(model.canOutput)
    }

    @Test("用紙を作っている間に設定を変えると、前の設定の用紙は公開しない", .timeLimit(.minutes(1)))
    func supersededCompositionIsNotPublished() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        defer { gate.release() }
        let model = try await renderedModel(suite, directory: directory, gate: gate)
        defer { model.stop() }

        gate.isHeld = true
        model.printOptions.showsPageNumbers = true
        model.render()
        try await waitUntil { gate.waiting == 1 }
        let superseded = try #require(model.result?.id)
        model.layoutID = PrintLayout.a4Duplex.id
        model.render()
        try await waitUntil { gate.waiting == 2 }
        // Both compositions go on; only the newer one may reach the tray.
        gate.release()
        var publishedSuperseded = false
        for _ in 0..<500 where model.isRendering {
            if model.printResult?.id == superseded { publishedSuperseded = true }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isRendering)
        #expect(!publishedSuperseded)
        #expect(model.printResult?.id != superseded)
        #expect(model.printResult?.id == model.result?.id)
        #expect(model.printResult?.plan.isDuplex == true)
        #expect(model.canOutput)
    }

    @Test("用紙を作れなかったら、前の用紙を今の用紙として扱わない", .timeLimit(.minutes(1)))
    func failedCompositionKeepsOldSheetsStale() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        defer { gate.release() }
        let model = try await renderedModel(suite, directory: directory, gate: gate)
        defer { model.stop() }
        let old = try #require(model.printResult)

        gate.failure = CompositionFailure()
        model.printOptions.showsPageNumbers = true
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.error != nil)
        #expect(model.result?.id != old.id)
        #expect(model.printResult?.id == old.id)
        #expect(!model.hasCurrentPrintPreview)
        #expect(!model.canOutput)
        #expect(FoldSource.current(model) == nil)
    }

    @Test("冊子の大きさを変えると、同じ論理 PDF でも折ってみるの白紙は新しい大きさで作り直す", .timeLimit(.minutes(1)))
    func foldFollowsBookletSize() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = try await renderedModel(suite, directory: directory, pages: 5, layout: .a3BookletA4)
        defer { model.stop() }
        let a4 = try #require(FoldSource.current(model))

        model.layoutID = PrintLayout.a4BookletA5.id
        model.render()
        try await waitUntil { !model.isRendering }
        let a5 = try #require(FoldSource.current(model))
        #expect(a5.document === a4.document)
        #expect(a5 != a4)

        let book = FoldBook()
        book.load(a5.document, pageSize: a5.pageSize, blankLabel: "Blank")
        #expect(book.contentPageCount == 5)
        #expect(book.pageCount == 8)
        for index in 5..<8 {
            let size = try #require(book.document?.page(at: index)).bounds(for: .mediaBox).size
            // A5 is 148 × 210 mm.
            #expect(abs(size.width - 419.53) < 0.5)
            #expect(abs(size.height - 595.28) < 0.5)
        }
    }

    @Test("刷り台の用紙は、面付けした用紙と同じ結果から作られる", .timeLimit(.minutes(1)))
    func trayFollowsComposedSheets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = try await renderedModel(suite, directory: directory, layout: .a3BookletA4)
        defer { model.stop() }
        let tray = try #require(model.printTray)
        #expect(tray.isBooklet)
        // 4 pages make one booklet sheet with a front and a back.
        #expect(tray.sheets.count == 1)
        #expect(tray.rows.count == 1)
        #expect(model.printResult?.sheetDocument.pageCount == 2)
    }
}

@MainActor
struct PrintSheetImageOrderTests {
    @Test("画像の束を並べ替えたら、新しい用紙ができるまで前の並びの刷り台を出さない", .timeLimit(.minutes(1)))
    func reorderHidesPreviousPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let urls = ["A.png", "B.png"].map { URL(fileURLWithPath: "/Images/\($0)") }
        let images = [urls[0]: TestFixtures.png(red: 1), urls[1]: TestFixtures.png(red: 0)]
        let bundle = ImageBundleModel(urls: urls) { url in
            guard let data = images[url] else { throw CocoaError(.fileNoSuchFile) }
            return data
        }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory), imageBundle: bundle)
        defer { model.stop() }
        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.hasCurrentPrintPreview)

        // The old result and its sheets still match each other, but their pages are in the old order.
        bundle.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(bundle.urls.map(\.lastPathComponent) == ["B.png", "A.png"])
        #expect(model.printResult?.id == model.result?.id)
        #expect(!model.hasCurrentPrintPreview)
        #expect(!model.canOutput)

        model.render()
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.hasCurrentPrintPreview)
    }
}
