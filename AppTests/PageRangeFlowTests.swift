import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct PageRangeFlowTests {
    @MainActor private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: TestDefaultsSuite

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }

        func model(_ data: Data, renderer: DocumentRenderer = DocumentRenderer()) -> DocumentViewModel {
            DocumentViewModel(
                data: data, fileURL: nil, format: .pdf, preferences: preferences, library: library,
                renderer: renderer, settingsStore: store)
        }
    }

    private func environment() -> Environment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        return Environment(
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            store: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")),
            directory: directory, suite: suite)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    /// A model on the tray with its sheets composed.
    private func trayModel(
        _ environment: Environment, pages: Int, layout: PrintLayout, renderer: DocumentRenderer = DocumentRenderer(),
        data: Data? = nil
    ) async throws -> DocumentViewModel {
        let model = environment.model(data ?? TestFixtures.pdf("range", pages: pages), renderer: renderer)
        model.layoutID = layout.id
        model.enterPrintMode()
        model.start()
        try await waitUntil { model.contentHash != nil && model.canOutput }
        return model
    }

    /// What the view does when the settings change.
    private func type(_ text: String, into model: DocumentViewModel) async throws {
        model.setPageRangeText(text)
        model.renderForChangedSettings()
        try await waitUntil { !model.isRendering }
    }

    private func pages(of tray: PrintTray?) -> [[[Int?]]] {
        (tray?.sheets ?? []).map { $0.sides.map(\.pages) }
    }

    @Test("範囲を入れると組版し直さずに面付けだけをやり直し、刷り台には出てくる用紙が文書の番号で並ぶ", .timeLimit(.minutes(1)))
    func rangeRecomposesOnly() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let renderer = DocumentRenderer()
        let model = try await trayModel(environment, pages: 12, layout: .a3BookletA4, renderer: renderer)
        defer { model.stop() }
        let layouts = renderer.logicalRenderCount
        let compositions = renderer.sheetCompositionCount
        #expect(model.printResult?.sheetDocument.pageCount == 6)

        try await type("5-12", into: model)
        #expect(renderer.logicalRenderCount == layouts)
        #expect(renderer.sheetCompositionCount == compositions + 1)
        #expect(model.canOutput)
        #expect(model.pageRangeProblem == nil)
        #expect(model.printResult?.sheetDocument.pageCount == 4)
        #expect(pages(of: model.printTray) == [[[12, 5], [6, 11]], [[10, 7], [8, 9]]])
        #expect(model.printResult?.summary.sheetCount == 2)
        #expect(model.printResult?.summary.logicalPageCount == 8)
    }

    @Test("3 ページを選んだ両面は最後の裏が白紙、2 アップは最後の右半分が白紙になる", .timeLimit(.minutes(1)))
    func blanksFollowTheRange() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 8, layout: .a4Duplex)
        defer { model.stop() }
        try await type("2, 4, 6", into: model)
        #expect(pages(of: model.printTray) == [[[2], [4]], [[6], [nil]]])
        model.layoutID = PrintLayout.a3TwoUp.id
        model.renderForChangedSettings()
        try await waitUntil { !model.isRendering }
        #expect(pages(of: model.printTray) == [[[2, 4]], [[6, nil]]])
    }

    @Test("すぐ印刷は部数と範囲の用紙を送り、システムの印刷画面にも同じ部数を渡す", .timeLimit(.minutes(1)))
    func printSendsCopiesAndRange() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 12, layout: .a4Single)
        defer { model.stop() }
        model.printerListSource = { PrinterList(names: ["Office Laser"], defaultName: "Office Laser") }
        model.refreshPrinters()
        try await type("3-5", into: model)
        model.copies = 3
        var submissions: [(RenderResult, PrintRequest, PrintPageOrder)] = []
        model.printSubmit = { submissions.append(($0, $1, $2)) }

        model.printDocument(quick: true)
        try #require(submissions.count == 1)
        #expect(submissions[0].1 == PrintRequest(printerName: "Office Laser", showsPanel: false, copies: 3))
        #expect(submissions[0].0.sheetDocument.pageCount == 3)
        #expect(submissions[0].0.plan.sides.map(\.slots) == [[2], [3], [4]])

        model.printDocument(quick: false)
        try #require(submissions.count == 2)
        #expect(submissions[1].1 == PrintRequest(printerName: "Office Laser", showsPanel: true, copies: 3))
    }

    @Test("PDF の書き出しも範囲の用紙を出す", .timeLimit(.minutes(1)))
    func exportUsesRange() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 12, layout: .a4Single)
        defer { model.stop() }
        try await type("１〜２、９", into: model)
        var exported: [RenderResult] = []
        model.outputOverride = { output, result in if output == .exportPDF { exported.append(result) } }
        model.exportPDF()
        try #require(exported.count == 1)
        #expect(exported[0].sheetDocument.pageCount == 3)
        #expect(exported[0].plan.sides.map(\.slots) == [[0], [1], [8]])
    }

    @Test("読めない範囲のあいだは印刷も書き出しもせず、直すと出せる", .timeLimit(.minutes(1)))
    func unreadableRangeHoldsOutputs() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 12, layout: .a4Single)
        defer { model.stop() }
        try await type("3-5", into: model)
        var outputs = 0
        model.outputOverride = { _, _ in outputs += 1 }

        try await type("9-7", into: model)
        #expect(model.pageRangeProblem == .unreadable)
        #expect(!model.canOutput)
        #expect(!model.canPerformPrintCommand)
        model.performPrintCommand()
        model.printDocument(quick: false)
        model.exportPDF()
        #expect(outputs == 0)
        // The tray keeps the sheets of the last range that could be read.
        #expect(model.pageRange == PageRange([3...5]))
        #expect(model.printResult?.sheetDocument.pageCount == 3)

        try await type("7-9", into: model)
        #expect(model.pageRangeProblem == nil)
        #expect(model.canOutput)
        model.exportPDF()
        #expect(outputs == 1)
    }

    @Test("文書にないページだけの範囲は全ページを刷り、欄にその番号のページがないと出す", .timeLimit(.minutes(1)))
    func rangeOutsideTheDocument() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 4, layout: .a4Single)
        defer { model.stop() }
        try await type("40-50", into: model)
        #expect(model.pageRangeProblem == .noSuchPages)
        #expect(model.canOutput)
        #expect(model.printResult?.sheetDocument.pageCount == 4)
        try await type("3-50", into: model)
        #expect(model.pageRangeProblem == nil)
        #expect(model.printResult?.sheetDocument.pageCount == 2)
    }

    @Test("表示モードは範囲があっても文書の全ページを見せる", .timeLimit(.minutes(1)))
    func viewModeShowsEverything() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 12, layout: .a4Single)
        defer { model.stop() }
        try await type("3-5", into: model)
        model.exitPrintMode()
        #expect(model.renderSettings?.pageRange == .all)
        model.renderForChangedSettings()
        try await waitUntil { !model.isRendering }
        #expect(model.result?.plan.logicalPageCount == 12)
        #expect(model.result?.logicalDocument.pageCount == 12)
    }

    @Test("打ちかけの読めない範囲は刷り台を出ると捨て、読めた範囲に戻す", .timeLimit(.minutes(1)))
    func halfTypedRangeIsDropped() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = try await trayModel(environment, pages: 12, layout: .a4Single)
        defer { model.stop() }
        try await type("3-5", into: model)
        try await type("3-5, x", into: model)
        model.exitPrintMode()
        #expect(model.pageRangeText == "3-5")
        #expect(model.pageRangeProblem == nil)
    }

    @Test("範囲は文書ごとに覚え、開き直すと戻り、設定を戻すと消える。部数は覚えない", .timeLimit(.minutes(1)))
    func rangeIsRemembered() async throws {
        let environment = environment()
        defer { environment.cleanUp() }
        // The record is kept by the bytes, and a PDF made twice is not the same bytes.
        let data = TestFixtures.pdf("range", pages: 12)
        let first = try await trayModel(environment, pages: 12, layout: .a4Single, data: data)
        try await type("1, 3, 7-9", into: first)
        first.copies = 4
        first.rememberedSettingsDidChange()
        first.stop()
        let key = try #require(first.contentHash)
        #expect(environment.store.record(for: key.hex)?.pageRange == PageRange([1...1, 3...3, 7...9]))

        let second = environment.model(data)
        defer { second.stop() }
        second.start()
        try await waitUntil { second.contentHash != nil && second.result != nil && !second.isRendering }
        #expect(second.pageRange == PageRange([1...1, 3...3, 7...9]))
        #expect(second.pageRangeText == "1, 3, 7-9")
        #expect(second.copies == 1)
        // Reading shows everything; the range waits for the tray.
        #expect(second.result?.plan.logicalPageCount == 12)
        second.enterPrintMode()
        second.render()
        try await waitUntil { second.canOutput }
        #expect(second.printResult?.sheetDocument.pageCount == 5)

        second.resetDocumentSettings()
        #expect(second.pageRange == .all)
        #expect(second.pageRangeText == "")
        #expect(environment.store.keys().isEmpty)
    }

    @Test("部数は 1 から 99 に収める")
    func copiesAreClamped() {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data())
        #expect(model.copies == 1)
        model.copies = 0
        #expect(model.copies == 1)
        model.copies = 250
        #expect(model.copies == 99)
    }

    @Test("範囲の刷り台でも、本文の何番目かから文書のページ番号を引き、刷らないページは行を持たない")
    func trayFindsBodyPages() {
        let plan = Imposition.plan(pages: [4, 5, 6, 7, 8, 9, 10, 11], layout: .a3BookletA4)
        let tray = PrintTray(plan: plan, layout: .a3BookletA4, rotatesBackSides: false)
        #expect(tray.bodyPage(at: 4) == 5)
        #expect(tray.rowID(containing: 5) == 0)
        #expect(tray.rowID(containing: 8) == 1)
        #expect(tray.bodyPage(at: 0) == 1)
        #expect(tray.rowID(containing: 1) == nil)
        #expect(tray.pageCount == 8)
    }

    @Test("折ってみるは範囲のページだけの冊子になり、ページの呼び名は文書の番号のままにする", .timeLimit(.minutes(1)))
    func foldBookOfRange() async throws {
        let document = try #require(PDFDocument(data: TestFixtures.pdf("fold", pages: 12)))
        let book = FoldBook()
        await book.load(
            document, pages: [4, 5, 6, 7, 8, 9], pageSize: PrintLayout.a3BookletA4.logicalPageSize, blankLabel: "Blank")
        #expect(book.contentPageCount == 6)
        #expect(book.pageCount == 8)
        #expect(book.pageNumber(at: 1) == 5)
        #expect(book.pageNumber(at: 6) == 10)
    }

    @Test("部数とページの欄を足しても、印刷の帯は幅 0 で聞かれて低いままで、エラーを出していても変わらない")
    func pressBarStaysLow() {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data())
        model.enterPrintMode()
        let plain = NSHostingController(rootView: PrintPressBar(model: model)).sizeThatFits(in: .zero)
        #expect(plain.height < 300)
        model.setPageRangeText("9-7")
        #expect(model.pageRangeProblem == .unreadable)
        let marked = NSHostingController(rootView: PrintPressBar(model: model)).sizeThatFits(in: .zero)
        #expect(marked.height < 300)
    }

    @Test("刷り台のいちばん狭い窓でも、印刷の帯はその幅に収まり、欄を足す前より 1 行分しか高くならない")
    func pressBarFitsMinimumTray() {
        let environment = environment()
        defer { environment.cleanUp() }
        let model = environment.model(Data())
        model.enterPrintMode()
        model.setPageRangeText("9-7")
        let width = PrintModeWindow.traySize.width
        let size = NSHostingController(rootView: PrintPressBar(model: model))
            .sizeThatFits(in: CGSize(width: width, height: 10_000))
        #expect(size.width <= width)
        #expect(size.height < 300)
    }
}
