import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// Holds or fails the sheet composition of a renderer, so a test sees the time between the logical pages and their
/// sheets.
@MainActor
final class CompositionGate {
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

    @Test("大きすぎるCSVは再読み込みを勧めずテキストとして開き直せる", .timeLimit(.minutes(1)))
    func oversizedTableRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let renderer = DocumentRenderer(paginate: { _ in
            try #require(PDFDocument(data: TestFixtures.pdf("Text")))
        })
        let model = DocumentViewModel(
            data: Data(String(repeating: "x,y\n", count: 60_001).utf8), fileURL: nil, format: .csv,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer { model.stop() }
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.layoutTooLarge && model.offersPlainTextRecovery)
        #expect(!model.canOutput)
        #expect(
            model.error
                == DocumentViewModel.message(for: DocumentRenderer.RenderingError.tooLarge(bytes: model.data.count)))
        model.reopenAsText()
        try await waitUntil { model.isUpToDate }
        #expect(!model.layoutTooLarge && !model.offersPlainTextRecovery)
    }

    @Test("先頭だけの紙を表示中は出力できず、全文に替わっても読んでいたページと倍率を保つ", .timeLimit(.minutes(1)))
    func readingPreviewSwap() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        gate.isHeld = true
        var passes = 0
        let renderer = DocumentRenderer(paginate: { _ in
            passes += 1
            if passes == 2 { try await gate.pass() }
            let pages = Array(repeating: "name value", count: passes == 1 ? 3 : 15)
            return try #require(PDFDocument(data: TestFixtures.textPDF(pages)))
        })
        let model = DocumentViewModel(
            data: Data(String(repeating: "name,value\n", count: 5_001).utf8), fileURL: nil, format: .csv,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        model.updateViewOptions {
            $0 = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ViewModeView(model: model))
        window.contentView = host
        defer {
            gate.release()
            model.closeWindow()
            window.contentView = nil
            window.close()
        }
        model.render()
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return gate.waiting == 1 && model.paper.view?.document?.pageCount == 3
                && model.paper.view?.visiblePages.isEmpty == false
        }
        let paper = try #require(model.paper.view)
        try #require(paper.window === window)
        let preview = try #require(model.readingPreview)
        #expect(model.paperDocument === preview.document && model.paperPageCount == 3)
        #expect(model.isRendering && model.result == nil && !model.isUpToDate)
        #expect(!model.canOutput && !model.canExportReadingPDF)
        #expect(!model.beginPDFExport())
        #expect(await model.beginThemedExport() == nil)
        model.toggleBookmark()
        #expect(model.bookmarks.isEmpty)
        model.find.text = "value"
        model.performFind()
        try await waitUntil { model.find.state.pages == [0, 1, 2] }
        paper.goToPage(index: 2)
        paper.setZoom(2, anchor: nil)
        try await waitUntil { model.shownPageIndex == 2 && model.zoom == 2 }
        let page = try #require(paper.document?.page(at: 2))
        // Start away from the page origin so a swap which merely restores the page index cannot pass.
        paper.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY)))
        let top = try #require(paper.currentDestination?.point)
        paper.go(to: PDFDestination(page: page, at: CGPoint(x: 110, y: 500)))
        let before = try #require(paper.currentDestination)
        try #require(before.page === page && abs(before.point.y - top.y) > 40)
        let position = before.point
        let magnification = paper.scaleFactor
        #expect(
            model.isPreparingWholeDocument && !model.hasContents
                && model.showsScrubberSlot == (model.menuArrangement == .split))
        #expect(!model.canTurnPaperPage(forward: true))
        #expect(!model.canRequestReadingPDF && !model.canRequestSheetOutput && !model.canExportReading(.richText))
        let menu = MenuSnapshot.Content(model: model, preferences: model.preferences)
        #expect(menu.enabled.contains(.documentPrint))
        let deferred: Set<ShortcutOperationID> = [
            .documentPrintSystem, .documentExportPDF, .documentExportReadingPDF, .documentExportPNG,
            .documentExportHTML, .documentCopyHTML, .documentCopyRichText, .documentShare,
        ]
        #expect(menu.enabled.isDisjoint(with: deferred))
        model.performPrintCommand()
        #expect(model.mode == .view && model.previewPrintRequest.destination == .currentLayout)
        model.chooseLayout(PrintLayout.a4Single.id)
        #expect(model.previewPrintRequest.destination == nil)
        gate.release()
        try await waitUntil { model.isUpToDate }
        #expect(model.readingPreview == nil && model.paperDocument !== preview.document)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return paper.document?.pageCount == 15 && paper.currentDestination?.page === paper.document?.page(at: 2)
        }
        try await waitUntil { model.find.state.pages == Array(0..<15) }
        let after = try #require(paper.currentDestination)
        #expect(model.paper.view === paper && paper.currentPageIndex == 2 && model.currentPageIndex == 2)
        #expect(model.zoom == 2 && paper.zoom == 2 && abs(paper.scaleFactor - magnification) < 0.01)
        #expect(abs(after.point.x - position.x) < 3 && abs(after.point.y - position.y) < 3)
        #expect(passes == 2 && model.canExportReadingPDF)
    }

    @Test(
        "新しい要求が来たら前の先頭PDFも全文PDFも遅れて表示されない",
        .timeLimit(.minutes(1)), arguments: [1, 2])
    func supersededReadingPass(heldPass: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        gate.isHeld = true
        var passes = 0
        let renderer = DocumentRenderer(paginate: { _ in
            passes += 1
            let pageCount = passes
            if passes == heldPass { try await gate.pass() }
            return try #require(PDFDocument(data: TestFixtures.pdf("generation", pages: pageCount)))
        })
        let model = DocumentViewModel(
            data: Data(String(repeating: "label,value\n", count: 5_001).utf8), fileURL: nil, format: .csv,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer {
            gate.release()
            model.stop()
        }
        model.render()
        let older = try #require(model.renderTask)
        try await waitUntil { gate.waiting == 1 }
        if heldPass == 2 { model.performPrintCommand() }
        model.replaceContent(Data("new log".utf8), format: .plainText)
        try await waitUntil { model.isUpToDate }
        let completed = try #require(model.result)
        gate.release()
        await older.value
        #expect(model.mode == .view && model.previewPrintRequest.destination == nil)
        #expect(model.result?.viewDocument === completed.viewDocument)
        #expect(model.readingPreview == nil && model.paperPageCount == heldPass + 1 && model.isUpToDate)
    }

    @Test(
        "全文を表示済みなら内容の再読み込みも余白変更も先頭の組版を省く",
        .timeLimit(.minutes(1)), arguments: [false, true])
    func completePaperStaysDuringReflow(changesMargins: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        var completePasses: [Bool] = []
        let renderer = DocumentRenderer(paginate: { request in
            guard case .html(let html, _) = request.source else { throw CocoaError(.fileReadCorruptFile) }
            let complete = html.contains("<td>LAST_RECORD</td>")
            completePasses.append(complete)
            try await gate.pass()
            return try #require(PDFDocument(data: TestFixtures.pdf("paper", pages: complete ? 8 : 2)))
        })
        let csv = String(repeating: "name,value\n", count: 5_001) + "LAST_RECORD,end"
        let model = DocumentViewModel(
            data: Data(csv.utf8), fileURL: nil, format: .csv,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer {
            gate.release()
            model.stop()
        }
        model.render()
        try await waitUntil { model.isUpToDate }
        let existing = try #require(model.paperDocument)
        #expect(completePasses == [false, true])
        model.paperDidChangePage(6)
        gate.isHeld = true
        if changesMargins {
            model.setMargins(model.printOptions.margins.top + 1)
            model.renderForChangedSettings()
        } else {
            model.replaceContent(Data((csv + ",changed").utf8), format: .csv)
        }
        try await waitUntil { gate.waiting == 1 }
        #expect(model.paperDocument === existing && model.readingPreview == nil)
        #expect(completePasses == [false, true, true])
        gate.release()
        try await waitUntil { model.isUpToDate }
        #expect(model.paperDocument !== existing && model.currentPageIndex == 6)
        #expect(completePasses == [false, true, true])
    }

    enum PreviewOutcome: CaseIterable { case success, failure, close }

    @Test(
        "全文の完成で刷り台を開き、失敗時は先頭の紙を残し、閉じた窓は開かない",
        .timeLimit(.minutes(1)), arguments: PreviewOutcome.allCases)
    func pendingTray(outcome: PreviewOutcome) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        gate.isHeld = true
        var passes = 0
        let renderer = DocumentRenderer(paginate: { _ in
            passes += 1
            if passes == 2 {
                try await gate.pass()
                if outcome == .failure { throw CocoaError(.fileReadCorruptFile) }
            }
            return try #require(PDFDocument(data: TestFixtures.pdf("paper", pages: 3)))
        })
        let model = DocumentViewModel(
            data: Data(String(repeating: "name,value\n", count: 5_001).utf8), fileURL: nil, format: .csv,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer {
            gate.release()
            model.stop()
        }
        model.printerListSource = { .empty }
        model.render()
        let rendering = try #require(model.renderTask)
        try await waitUntil { gate.waiting == 1 }
        let prefix = try #require(model.readingPreview?.document)
        model.chooseLayout(PrintLayout.a4Single.id)
        #expect(model.previewPrintRequest.destination == .layout(PrintLayout.a4Single.id))
        if outcome == .close { model.closeWindow() }
        gate.release()
        await rendering.value
        #expect(model.previewPrintRequest.destination == nil && !model.isPreparingWholeDocument)
        switch outcome {
        case .success:
            #expect(model.mode == .print && model.layoutID == PrintLayout.a4Single.id)
        case .failure:
            #expect(model.mode == .view && model.paperDocument === prefix && model.error != nil)
            #expect(!model.canRequestPrint && !model.canExportReading(.png))
            model.performPrintCommand()
            #expect(model.previewPrintRequest.destination == nil)
        case .close: #expect(model.mode == .view && model.isWindowClosed)
        }
    }

    @Test("表示では用紙を作らず刷り台に入ると同じ論理ページを順に面付けする", .timeLimit(.minutes(1)))
    func firstTrayVisit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let gate = CompositionGate()
        let renderer = DocumentRenderer()
        renderer.willComposeSheet = { try await gate.pass() }
        let model = DocumentViewModel(
            data: TestFixtures.textPDF(["Page One", "Page Two"]), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        defer {
            model.stop()
            gate.release()
        }
        model.layoutID = PrintLayout.a4Single.id
        model.render()
        try await waitUntil { model.isUpToDate }
        let logical = try #require(model.result?.logicalDocument)
        #expect(model.printResult == nil)
        #expect(!model.canOutput)
        #expect(renderer.sheetCompositionCount == 0)
        gate.isHeld = true
        model.enterPrintMode()
        try await waitUntil { gate.waiting == 1 }
        #expect(model.isRendering && !model.hasCurrentPrintPreview && !model.canOutput)
        gate.release()
        try await waitUntil { model.canOutput }
        let output = try #require(model.printResult)
        #expect(output.logicalDocument === logical)
        #expect(output.sheetDocument.pageCount == 2)
        for (index, label) in ["Page One", "Page Two"].enumerated() {
            let page = try #require(output.sheetDocument.page(at: index))
            #expect(page.string == label)
            #expect(abs(page.bounds(for: .mediaBox).width - 595.28) < 0.5)
        }
        #expect(renderer.sheetCompositionCount == 1)
    }

    @Test(
        "表示からの書き出しと印刷は刷り台に入り、選んだレイアウトの用紙ができるまで保留する",
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
        // The view mode shows the new layout too, so the A4 pages still on the paper are no longer output.
        #expect(!model.canOutput)
        #expect(model.renderedSettings?.layout == .a4Single)

        var outputs: [(DocumentViewModel.Output, RenderResult)] = []
        model.outputOverride = { outputs.append(($0, $1)) }
        gate.isHeld = true
        switch output {
        case .exportPDF: model.exportPDF()
        case .exportReadingPDF: model.exportReadingPDF()
        case .additional(let kind): model.exportReading(kind)
        case .print(let quick): model.printDocument(quick: quick)
        case .manualDuplex: model.printDocument(intent: .manualDuplex)
        }
        #expect(model.mode == .print)
        #expect(model.outputAfterReview == output)
        #expect(!model.canOutput)
        #expect(!model.isExporting && !model.isPrinting)
        #expect(outputs.isEmpty)

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
        // The view mode shows the pages of the chosen layout too.
        #expect(model.renderSettings?.layout == .a4BookletA5)
    }

    @Test("論理ページを出してから用紙ができるまでは、刷り台は前の用紙を見せたままにし、出力と折ってみるには使わない", .timeLimit(.minutes(1)))
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
        model.printOptions.furniture = .pageNumber
        model.render()
        try await waitUntil { gate.waiting == 1 }
        // The paper already has the new render, with the same logical document; its sheets are not composed yet.
        #expect(model.result?.id != old.id)
        #expect(model.result?.logicalDocument === old.logicalDocument)
        #expect(model.printResult?.id == old.id)
        #expect(!model.hasCurrentPrintPreview)
        #expect(model.showsTrayPreview)
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
        model.printOptions.furniture = .pageNumber
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
        model.printOptions.furniture = .pageNumber
        model.render()
        try await waitUntil { !model.isRendering }
        #expect(model.error != nil)
        #expect(model.result?.id != old.id)
        #expect(model.printResult?.id == old.id)
        #expect(!model.hasCurrentPrintPreview)
        #expect(!model.canOutput)
        #expect(FoldSource.current(model) == nil)
    }

    @Test("窓に載せた折り見本は右とじの見開きを示し左とじへ切り替えられる", .timeLimit(.minutes(1)))
    func rightFoldInWindow() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let model = try await renderedModel(suite, directory: directory, pages: 8, layout: .a4BookletA5)
        defer { model.stop() }
        model.bookletBinding = .right
        model.render()
        try await waitUntil { !model.isRendering }
        let host = NSHostingView(rootView: PrintFoldView(model: model, close: {}))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.alphaValue = 0
        window.orderFront(nil)
        func pdfView(in view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }
        try await waitUntil { pdfView(in: host)?.document?.pageCount == 8 }
        let view = try #require(pdfView(in: host))
        #expect(view.displaysRTL)
        let second = try #require(view.document?.page(at: 1))
        let third = try #require(view.document?.page(at: 2))
        view.go(to: second)
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        #expect(
            view.convert(second.bounds(for: .cropBox), from: second).minX > view.convert(
                third.bounds(for: .cropBox), from: third
            ).minX + 3)
        model.bookletBinding = .left
        model.render()
        try await waitUntil { !model.isRendering && !view.displaysRTL }
        #expect(FoldSource.current(model)?.rightBound == false)
    }

    @Test("冊子の大きさを変えると、同じ論理 PDF でも折ってみるの紙は中身も白紙も新しい大きさで作り直す", .timeLimit(.minutes(1)))
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
        await book.load(a5.document, pageSize: a5.pageSize, blankLabel: "Blank")
        #expect(book.contentPageCount == 5)
        #expect(book.pageCount == 8)
        for index in 0..<8 {
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
        model.enterPrintMode()
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
