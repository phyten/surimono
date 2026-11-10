import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrintJobTitleTests {
    private func model(url: URL?, title: String? = nil) -> (DocumentViewModel, () -> Void) {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Job", pages: 2), fileURL: url, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root), title: title)
        return (
            model,
            {
                model.stop()
                try? FileManager.default.removeItem(at: root)
                suite.remove()
            }
        )
    }

    private func render(_ model: DocumentViewModel) async throws -> RenderResult {
        model.start()
        model.enterPrintMode()
        for _ in 0..<500 where model.printResult == nil || model.isRendering {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.printResult)
    }

    @Test("印刷のジョブはファイルの名前を名乗り、すぐ刷るときもシステムの印刷画面でも同じ", .timeLimit(.minutes(1)))
    func documentJobTitle() async throws {
        let (model, cleanUp) = model(url: URL(fileURLWithPath: "/fixtures/議事録.pdf"))
        defer { cleanUp() }
        let result = try await render(model)
        #expect(model.printJobTitle == "議事録.pdf")
        let quick = try #require(
            model.makePrintOperation(
                for: result, request: PrintRequest(printerName: nil, showsPanel: false),
                pageOrder: .lastSheetFirst))
        #expect(quick.jobTitle == "議事録.pdf")
        let dialog = try #require(
            model.makePrintOperation(
                for: result, request: PrintRequest(printerName: nil, showsPanel: true), pageOrder: .lastSheetFirst))
        #expect(dialog.jobTitle == "議事録.pdf")
        #expect(dialog.showsPrintPanel)
    }

    @Test("ファイルのない文書のジョブは窓と同じ題を名乗る", .timeLimit(.minutes(1)))
    func untitledJobTitle() async throws {
        let (model, cleanUp) = model(url: nil, title: "Clipboard 0:13")
        defer { cleanUp() }
        #expect(model.printJobTitle == "Clipboard 0:13")
    }

    @Test("両面のテスト印刷のジョブは、文書の名前ではなくテスト印刷だと名乗る", .timeLimit(.minutes(1)))
    func duplexTestJobTitle() async throws {
        #expect(DocumentViewModel.duplexTestJobTitle(language: "en") == "Duplex Test Print")
        #expect(DocumentViewModel.duplexTestJobTitle(language: "ja") == "両面のテスト印刷")
        let (model, cleanUp) = model(url: URL(fileURLWithPath: "/fixtures/議事録.pdf"))
        defer { cleanUp() }
        let sheet = try #require(PDFDocument(data: TestFixtures.pdf("Test", pages: 2)))
        let operation = try #require(
            model.makeDuplexTestOperation(
                for: sheet, layout: .a4Duplex, request: PrintRequest(printerName: nil, showsPanel: true)))
        #expect(operation.jobTitle == DocumentViewModel.duplexTestJobTitle(language: model.language))
    }
}
