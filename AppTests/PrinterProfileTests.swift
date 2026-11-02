import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct PrinterProfileFlowTests {
    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let data = TestFixtures.pdf("Printer test", pages: 4)
        var store: DocumentSettingsStore { DocumentSettingsStore(directory: root.appendingPathComponent("Settings")) }

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            preferences.layoutID = "a4BookletA5"
        }

        func model(renderer: DocumentRenderer = DocumentRenderer(), data: Data? = nil) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: data ?? self.data, fileURL: nil, format: .pdf, preferences: preferences,
                library: UserLibrary(root: root.appendingPathComponent("Library")), renderer: renderer,
                settingsStore: store)
            model.printerListSource = { PrinterList(names: ["A", "B"], defaultName: "A") }
            model.refreshPrinters()
            return model
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            suite.remove()
        }
    }

    private func waitForRender(_ model: DocumentViewModel) async throws {
        for _ in 0..<500 where model.isRendering || model.contentHash == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isRendering && model.contentHash != nil)
        try #require(model.error == nil)
    }

    @Test("プリンターを切り替えると裏面の見本と注記が変わり論理ページは再利用する", .timeLimit(.minutes(1)))
    func switching() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        let model = fixture.model()
        defer { model.stop() }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        let logical = try #require(model.result?.logicalDocument)
        #expect(model.rotatesBackSides)
        #expect(model.printTray?.sheets.first?.sides.last?.isRotated == true)
        #expect(
            PrintModeText.options(model.effectivePrintOptions, layout: model.layout, language: "en")
                == "Back sides rotated 180°")
        model.selectPrinter("B")
        #expect(!model.rotatesBackSides)
        #expect(!model.canOutput)
        model.render()
        try await waitForRender(model)
        #expect(model.result?.logicalDocument === logical)
        #expect(model.printTray?.sheets.first?.sides.last?.isRotated == false)
        #expect(PrintModeText.options(model.effectivePrintOptions, layout: model.layout, language: "en") == nil)
        model.layoutID = "a4Duplex"
        model.selectPrinter("A")
        #expect(!model.rotatesBackSides)
    }

    @Test("印刷直前にAが外れたらB用のPDFを待ちシステム画面で一度だけ送る", .timeLimit(.minutes(1)))
    func recomposeBeforeSubmission() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        fixture.preferences.setPrinterRotation(false, for: "B", duplex: .shortEdge)
        fixture.preferences.setPrinterPageOrder(.firstSheetFirst, for: "B")
        let renderer = DocumentRenderer()
        let model = fixture.model(renderer: renderer, data: try asymmetricPDF())
        defer { model.stop() }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        let previous = try #require(model.printResult)
        let expected = try await PDFComposer().compose(
            previous.logicalDocument, layout: .a4BookletA5, options: PrintOptions(rotatesBackSides: false))
        let beforePixels = try backPixels(previous.sheetDocument)
        let expectedPixels = try backPixels(expected)
        try #require(beforePixels != expectedPixels)
        let logicalCount = renderer.logicalRenderCount
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        renderer.willComposeSheet = { await withCheckedContinuation { release = $0 } }
        model.printerListSource = { PrinterList(names: ["B"], defaultName: "B") }
        var submissions: [(RenderResult, PrintRequest, PrintPageOrder)] = []
        model.printSubmit = { submissions.append(($0, $1, $2)) }
        model.printDocument(quick: true)
        model.printDocument(quick: true)
        #expect(submissions.isEmpty)
        for _ in 0..<500 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(release != nil)
        #expect(model.renderedSettings?.options.rotatesBackSides == false)
        #expect(submissions.isEmpty)
        model.printDocument(quick: false)
        model.printDocument(quick: true)
        renderer.willComposeSheet = nil
        release?.resume()
        release = nil
        try await waitForRender(model)
        try #require(submissions.count == 1)
        #expect(submissions[0].1 == PrintRequest(printerName: "B", showsPanel: true))
        #expect(submissions[0].2 == .firstSheetFirst)
        #expect(try backPixels(submissions[0].0.sheetDocument) == expectedPixels)
        #expect(renderer.logicalRenderCount == logicalCount)
        model.render()
        try await waitForRender(model)
        #expect(submissions.count == 1)
    }

    @Test("プリンター切替の面付けに失敗した印刷は後の描画で送らない", .timeLimit(.minutes(1)))
    func failedPendingPrint() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        let renderer = DocumentRenderer()
        let model = fixture.model(renderer: renderer)
        defer { model.stop() }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        var submissions = 0
        model.printSubmit = { _, _, _ in submissions += 1 }
        model.printerListSource = { PrinterList(names: ["B"], defaultName: "B") }
        renderer.willComposeSheet = { throw CocoaError(.fileReadUnknown) }
        model.printDocument(quick: true)
        for _ in 0..<500 where model.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.error != nil)
        #expect(submissions == 0)
        renderer.willComposeSheet = nil
        model.render()
        try await waitForRender(model)
        #expect(submissions == 0)
        model.printDocument(quick: true)
        #expect(submissions == 1)
    }

    @Test("面付け待ちで刷り台を閉じた印刷は次に開いても送らない", .timeLimit(.minutes(1)))
    func cancelledPendingPrint() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        let model = fixture.model()
        defer { model.stop() }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        var submissions = 0
        model.printSubmit = { _, _, _ in submissions += 1 }
        model.printerListSource = { PrinterList(names: ["B"], defaultName: "B") }
        model.printDocument(quick: true)
        model.exitPrintMode()
        model.render()
        try await waitForRender(model)
        model.enterPrintMode()
        model.render()
        try await waitForRender(model)
        #expect(submissions == 0)
        model.printDocument(quick: true)
        #expect(submissions == 1)
    }

    private func asymmetricPDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 35, y: 55, width: 90, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func backPixels(_ document: PDFDocument) throws -> Data {
        let page = try #require(document.page(at: 1))
        let thumbnail = page.thumbnail(of: CGSize(width: 240, height: 170), for: .mediaBox)
        let tiff = try #require(thumbnail.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @Test("回転と出てくる順を変えても文書設定は保存せず選んだプリンターだけに覚える", .timeLimit(.minutes(1)))
    func manualChanges() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        let before = model.rememberedSettings
        model.rotatesBackSides = true
        model.printPageOrder = .firstSheetFirst
        model.rememberedSettingsDidChange()
        model.stop()
        #expect(model.rememberedSettings == before)
        #expect(!model.hasSavedSettings)
        #expect(fixture.store.record(for: ContentHash.of(fixture.data).hex) == nil)
        let restored = AppPreferences(defaults: fixture.suite.defaults)
        #expect(restored.printerProfile(for: "A").rotatesBackSides[.shortEdge] == true)
        #expect(restored.printerProfile(for: "A").pageOrder == .firstSheetFirst)
        #expect(restored.printerProfiles["B"] == nil)
        #expect(!restored.rotateBack && restored.printPageOrder == .lastSheetFirst)
        model.selectPrinter("B")
        #expect(model.printPageOrder == .lastSheetFirst)
        model.selectPrinter("A")
        model.resetDocumentSettings()
        #expect(model.rotatesBackSides)
    }

    @Test("保存済み文書の回転を無視してプリンターの未設定値だけを既定値で補う", .timeLimit(.minutes(1)))
    func legacyDocument() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let hash = ContentHash.of(fixture.data).hex
        let directory = fixture.root.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            #"{"layoutID":"a4BookletA5","printOptions":{"marginsInMillimeters":12,"showsPageNumbers":true,"rotatesBackSides":true}}"#
                .utf8
        )
        .write(to: directory.appendingPathComponent(hash + ".json"))
        let model = fixture.model()
        defer { model.stop() }
        model.start()
        try await waitForRender(model)
        model.enterPrintMode()
        #expect(model.printOptions.marginsInMillimeters == 12)
        #expect(model.printOptions.showsPageNumbers)
        #expect(!model.rotatesBackSides)
        fixture.preferences.rotateBack = true
        #expect(model.rotatesBackSides)
        model.rotatesBackSides = false
        #expect(!model.rotatesBackSides)
        #expect(fixture.preferences.rotateBack)
        let recordURL = directory.appendingPathComponent(hash + ".json")
        let before = try Data(contentsOf: recordURL)
        model.rememberedSettingsDidChange()
        model.stop()
        #expect(try Data(contentsOf: recordURL) == before)
    }

    @Test("壊れたプリンター設定だけを捨て残りを読み戻す")
    func tolerantPreferences() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        suite.defaults.set(
            Data(#"{"A":{"rotatesBackSides":{"shortEdge":true}},"B":42,"C":{"pageOrder":"firstSheetFirst"}}"#.utf8),
            forKey: "printerProfiles")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.printerProfile(for: "A").rotatesBackSides[.shortEdge] == true)
        #expect(preferences.printerProfiles["B"] == nil)
        #expect(preferences.printerProfile(for: "C").pageOrder == .firstSheetFirst)
    }

    @Test("テスト印刷の答えは開始時のプリンターと綴じ方へ保存する", arguments: [false, true])
    func testAnswer(rotates: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        var submission: (PDFDocument, PrintLayout, PrintRequest)?
        model.duplexTestSubmit = { document, layout, request, complete in
            submission = (document, layout, request)
            complete(.init(printerName: "A", duplex: layout.duplex))
        }
        model.printDuplexTest()
        for _ in 0..<100 where model.isPrinting { try await Task.sleep(for: .milliseconds(10)) }
        let sent = try #require(submission)
        #expect(sent.0.pageCount == 2)
        #expect(
            sent.1.kind == .normal && sent.1.duplex == .shortEdge && sent.1.sheetSize.width < sent.1.sheetSize.height)
        #expect(sent.2 == PrintRequest(printerName: "A", showsPanel: false))
        model.selectPrinter("B")
        model.layoutID = "a4Duplex"
        model.answerDuplexTest(rotatesBackSides: rotates)
        #expect(fixture.preferences.printerProfile(for: "A").rotatesBackSides[.shortEdge] == rotates)
        #expect(fixture.preferences.printerProfiles["B"] == nil)
        #expect(model.duplexTestResult == nil)
        model.selectPrinter("A")
        model.layoutID = "a4BookletA5"
        #expect(model.rotatesBackSides == rotates)
    }

    @Test("プリンターが外れたテストはシステム画面を頼み実際の送り先へ答えを保存する")
    func changedPrinter() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.setPrinterRotation(true, for: "A", duplex: .shortEdge)
        let model = fixture.model()
        defer { model.stop() }
        model.printerListSource = { PrinterList(names: ["B"], defaultName: "B") }
        var requests: [PrintRequest] = []
        var documents: [PDFDocument] = []
        model.duplexTestSubmit = { document, layout, sent, complete in
            requests.append(sent)
            documents.append(document)
            complete(.init(printerName: "B", duplex: layout.duplex))
        }
        model.printDuplexTest()
        model.printDuplexTest()
        for _ in 0..<100 where model.isPrinting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requests == [PrintRequest(printerName: "B", showsPanel: true)])
        #expect(documents.first?.pageCount == 2)
        #expect(documents.first?.page(at: 1)?.rotation == 0)
        model.answerDuplexTest(rotatesBackSides: true)
        #expect(fixture.preferences.printerProfile(for: "A").rotatesBackSides[.shortEdge] == true)
        #expect(fixture.preferences.printerProfile(for: "B").rotatesBackSides[.shortEdge] == true)
    }

    @Test("片面ではテストを送らずキャンセルとあとでは何も保存しない")
    func cancellation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        var count = 0
        model.duplexTestSubmit = { _, _, _, complete in
            count += 1
            complete(nil)
        }
        model.layoutID = "a4Single"
        model.printDuplexTest()
        #expect(count == 0)
        model.layoutID = "a4Duplex"
        model.printDuplexTest()
        for _ in 0..<100 where model.isPrinting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(count == 1 && model.duplexTestResult == nil)
        model.duplexTestResult = .init(printerName: "A", duplex: .longEdge)
        model.answerDuplexTest(rotatesBackSides: nil)
        #expect(fixture.preferences.printerProfiles.isEmpty)
    }
}
