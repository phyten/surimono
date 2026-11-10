import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct PrinterIssueTests {
    /// Counts the questions; the answers come from a table, so no test asks a real printer.
    private final class Printers: @unchecked Sendable {
        // Guarded by the lock: the source is called off the main actor.
        private let lock = NSLock()
        private var asked: [String] = []
        private let answers: [String: PrinterCapabilities]

        init(_ answers: [String: PrinterCapabilities]) { self.answers = answers }

        var questions: [String] { lock.withLock { asked } }

        func capabilities(for name: String) -> PrinterCapabilities? {
            lock.withLock { asked.append(name) }
            return answers[name]
        }
    }

    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences: AppPreferences
        let printers = Printers([
            "A4 Only": PrinterCapabilities(paperSizes: [CGSize(width: 595, height: 842)], duplex: true),
            "One Side": PrinterCapabilities(
                paperSizes: [CGSize(width: 595, height: 842), CGSize(width: 842, height: 1191)], duplex: false),
        ])

        init() {
            preferences = AppPreferences(defaults: suite.defaults)
            preferences.layoutID = "a3BookletA4"
        }

        func model(names: [String] = ["A4 Only", "One Side", "Unknown"]) -> DocumentViewModel {
            let model = DocumentViewModel(
                data: TestFixtures.pdf("Printer issue test", pages: 4), fileURL: nil, format: .pdf,
                preferences: preferences, library: UserLibrary(root: root.appendingPathComponent("Library")),
                renderer: DocumentRenderer(),
                settingsStore: DocumentSettingsStore(directory: root.appendingPathComponent("Settings")))
            model.printerListSource = { PrinterList(names: names, defaultName: names.first) }
            model.printerCapabilitiesSource = { [printers] in printers.capabilities(for: $0) }
            return model
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            suite.remove()
        }
    }

    private func waitForAnswers(_ model: DocumentViewModel) async throws {
        for _ in 0..<500 where !model.printerCapabilityQueries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.printerCapabilityQueries.isEmpty)
    }

    private func waitForRender(_ model: DocumentViewModel) async throws {
        for _ in 0..<500 where model.isRendering || model.contentHash == nil || !model.canOutput {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.canOutput)
    }

    @Test("プリンターの答えが届くまではバッジを出さず、届くと刷れないレイアウトに付く")
    func badgesAppearWhenThePrinterAnswers() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.refreshPrinters()
        #expect(model.printerIssue(for: .a3BookletA4) == nil)
        try await waitForAnswers(model)
        #expect(model.printerIssue(for: .a3BookletA4) == .paperNotAccepted(.a3))
        #expect(model.printerIssue(for: .a3TwoUp) == .paperNotAccepted(.a3))
        #expect(model.printerIssue(for: .a4Duplex) == nil)
        #expect(model.printerIssue(for: .a4Single) == nil)
    }

    @Test("プリンターを選び直すと、バッジはそのプリンターのものに変わる")
    func badgesFollowTheChosenPrinter() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.refreshPrinters()
        try await waitForAnswers(model)
        model.selectPrinter("One Side")
        try await waitForAnswers(model)
        #expect(model.printerIssue(for: .a3BookletA4) == .duplexNotAvailable)
        #expect(model.printerIssue(for: .a4Duplex) == .duplexNotAvailable)
        #expect(model.printerIssue(for: .a3TwoUp) == nil)
        model.selectPrinter("A4 Only")
        #expect(model.printerIssue(for: .a3TwoUp) == .paperNotAccepted(.a3))
    }

    @Test("何ができるか分からないプリンターでは、どのレイアウトにもバッジを出さない", arguments: PrintLayout.presets)
    func unknownPrinterShowsNoBadge(layout: PrintLayout) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.refreshPrinters()
        model.selectPrinter("Unknown")
        try await waitForAnswers(model)
        #expect(model.selectedPrinterName == "Unknown")
        #expect(model.printerIssue(for: layout) == nil)
    }

    @Test("プリンターが 1 台もなければ、何も聞かず、バッジも出さない")
    func noPrinters() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(names: [])
        model.refreshPrinters()
        try await waitForAnswers(model)
        #expect(fixture.printers.questions.isEmpty)
        #expect(model.printerIssue(for: .a3BookletA4) == nil)
    }

    @Test("刷り台を開いている間に選んだプリンターが外されると、バッジは代わりのプリンターのものに変わる")
    func badgesFollowARemovedPrinter() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.refreshPrinters()
        try await waitForAnswers(model)
        #expect(model.printerIssue(for: .a3TwoUp) == .paperNotAccepted(.a3))
        model.printerListSource = { PrinterList(names: ["One Side"], defaultName: "One Side") }
        model.refreshPrinters()
        try await waitForAnswers(model)
        #expect(model.printerIssue(for: .a3TwoUp) == nil)
        #expect(model.printerIssue(for: .a4Duplex) == .duplexNotAvailable)
    }

    @Test("答えたプリンターには、一覧を読み直しても聞き直さない")
    func asksEachPrinterOnce() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.refreshPrinters()
        model.refreshPrinters()
        try await waitForAnswers(model)
        model.refreshPrinters()
        model.selectPrinter("One Side")
        try await waitForAnswers(model)
        model.selectPrinter("A4 Only")
        model.refreshPrinters()
        try await waitForAnswers(model)
        #expect(fixture.printers.questions == ["A4 Only", "One Side"])
    }

    @Test("刷れないレイアウトのまま「印刷」を押すと、黙って送らずシステムの印刷画面を開く", .timeLimit(.minutes(1)))
    func quickPrintAsksWhenThePrinterCannot() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        var requests: [PrintRequest] = []
        model.printSubmit = { _, request, _ in requests.append(request) }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        try await waitForAnswers(model)
        #expect(model.printerIssue == .paperNotAccepted(.a3))
        model.performPrintCommand()
        #expect(requests == [PrintRequest(printerName: "A4 Only", showsPanel: true)])
    }

    @Test("刷れるレイアウトの「印刷」は、今までどおりダイアログなしで送る", .timeLimit(.minutes(1)))
    func quickPrintStaysSilentWithoutAnIssue() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.layoutID = "a4BookletA5"
        let model = fixture.model()
        defer { model.stop() }
        var requests: [PrintRequest] = []
        model.printSubmit = { _, request, _ in requests.append(request) }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        try await waitForAnswers(model)
        #expect(model.printerIssue == nil)
        model.performPrintCommand()
        #expect(requests == [PrintRequest(printerName: "A4 Only", showsPanel: false)])
    }

    /// Prints the duplex test of a model on the tray and returns what was sent.
    private func duplexTestRequest(
        _ fixture: Fixture, layoutID: String, printer: String
    ) async throws -> (PrintLayout, PrintRequest) {
        fixture.preferences.layoutID = layoutID
        fixture.preferences.printerName = printer
        let model = fixture.model()
        defer { model.stop() }
        var sent: (PrintLayout, PrintRequest)?
        model.duplexTestSubmit = { _, layout, request, complete in
            sent = (layout, request)
            complete(nil)
        }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        try await waitForAnswers(model)
        #expect(model.selectedPrinterName == printer)
        model.printDuplexTest()
        for _ in 0..<500 where model.isPrinting { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(sent)
    }

    @Test("用紙を受け付けないプリンターへの両面テスト印刷は、黙って送らずシステムの印刷画面を開く", .timeLimit(.minutes(1)))
    func duplexTestAsksWhenThePaperIsNotAccepted() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (layout, request) = try await duplexTestRequest(fixture, layoutID: "a3BookletA4", printer: "A4 Only")
        #expect(layout.sheet == .a3)
        #expect(request == PrintRequest(printerName: "A4 Only", showsPanel: true))
    }

    @Test("両面で刷れないプリンターへの両面テスト印刷は、黙って送らずシステムの印刷画面を開く", .timeLimit(.minutes(1)))
    func duplexTestAsksWhenDuplexIsNotAvailable() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (layout, request) = try await duplexTestRequest(fixture, layoutID: "a4Duplex", printer: "One Side")
        #expect(layout.sentDuplex == .longEdge)
        #expect(request == PrintRequest(printerName: "One Side", showsPanel: true))
    }

    @Test(
        "刷れるプリンターと、何も答えないプリンターへの両面テスト印刷は、今までどおりダイアログなしで送る",
        .timeLimit(.minutes(1)), arguments: ["A4 Only", "Unknown"])
    func duplexTestStaysQuick(printer: String) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let (_, request) = try await duplexTestRequest(fixture, layoutID: "a4BookletA5", printer: printer)
        #expect(request == PrintRequest(printerName: printer, showsPanel: false))
    }

    @Test("刷れないレイアウトでも、PDF の書き出しはそのままできる", .timeLimit(.minutes(1)))
    func exportIsUnaffected() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        defer { model.stop() }
        var outputs: [DocumentViewModel.Output] = []
        model.outputOverride = { output, _ in outputs.append(output) }
        model.enterPrintMode()
        model.start()
        try await waitForRender(model)
        try await waitForAnswers(model)
        #expect(model.printerIssue == .paperNotAccepted(.a3))
        model.exportPDF()
        model.performPrintCommand()
        #expect(outputs == [.exportPDF, .print(quick: false)])
    }

    @Test("バッジの文言はカードの読み上げに含まれ、ヒントは刷れない理由を文で伝える")
    func badgeWords() {
        #expect(PrintModeText.issueBadge(.paperNotAccepted(.a3), language: "ja") == "A3 なし")
        #expect(PrintModeText.issueBadge(.duplexNotAvailable, language: "ja") == "両面なし")
        #expect(PrintModeText.issueBadge(.paperNotAccepted(.b4), language: "en") == "No B4")
        #expect(
            PrintModeText.cardLabel(.a3BookletA4, issue: .paperNotAccepted(.a3), language: "ja")
                == "\(PrintLayout.a3BookletA4.displayName(language: "ja")), A3 なし")
        #expect(
            PrintModeText.cardLabel(.a4Single, issue: nil, language: "ja")
                == PrintLayout.a4Single.displayName(language: "ja"))
        #expect(
            PrintModeText.cardHelp("A4 両面 (⌘2)", issue: .duplexNotAvailable, language: "ja")
                == "A4 両面 (⌘2)\nこのプリンターは両面に刷れません")
        #expect(PrintModeText.cardHelp("A4 片面 (⌘1)", issue: nil, language: "ja") == "A4 片面 (⌘1)")
    }

    @Test("刷れないレイアウトを選んでいる間、要約の行は理由と、印刷がシステムの印刷画面を開くことを伝える")
    func summaryLine() {
        #expect(
            PrintModeText.issueLine(.paperNotAccepted(.a3), language: "ja")
                == "このプリンターは A3 に刷れません。「印刷」はシステムの印刷画面を開きます。")
        #expect(
            PrintModeText.issueLine(.duplexNotAvailable, language: "en")
                == "This printer cannot print on both sides. Print opens the system print dialog.")
    }

    @Test("バッジと要約の行が出ていても、印刷の帯は幅0で大きさを聞かれて低いままでいる")
    func pressBarStaysLowWithBadges() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        model.enterPrintMode()
        try await waitForAnswers(model)
        #expect(model.printerIssue == .paperNotAccepted(.a3))
        let size = NSHostingController(rootView: PrintPressBar(model: model)).sizeThatFits(in: .zero)
        #expect(size.height < 300)
    }
}
