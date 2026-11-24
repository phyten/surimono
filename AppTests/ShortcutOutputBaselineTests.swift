import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// No system printers, registrations, file panels or submissions are reachable from this fixture.
@MainActor
final class ShortcutOutputFixture {
    static let keyboardLayout = ShortcutKeyboardLayout.project { code, flags in
        switch code {
        case 38: "j"
        case 40: "k"
        case 35: "p"
        case 24: flags.contains(.shift) ? "+" : "="
        default: nil
        }
    }
    let suite = TestDefaultsSuite()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    lazy var owner = NSWindowController(window: window)
    lazy var preferences = AppPreferences(defaults: suite.defaults)
    let hotKeys = GlobalHotKeys(register: { _, _ in
        Issue.record("Real global registration is forbidden")
        return nil
    })
    lazy var controller = ShortcutController(
        hotKeys: hotKeys, reservations: { [] }, keyboardLayout: { ShortcutOutputFixture.keyboardLayout })
    lazy var menus = SystemMenuShortcuts(controller: controller, preferences: { [unowned self] in preferences })
    lazy var dispatcher = ShortcutDispatcher(
        controller: controller, menus: menus, keyWindow: { [unowned self] in activeWindow },
        model: { [unowned self] in model }, firstResponder: { [unowned self] _ in responder },
        menuTrackingDepth: { [unowned self] in trackingDepth })
    var trackingDepth = 0
    var activeWindow: NSWindow?
    var responder: NSResponder? = NSView()
    var model: DocumentViewModel!
    var submissions: [PrintRequest] = []
    var exports = 0
    var allowsPrint = false
    var allowsExport = false

    init(format: DocumentFormat = .pdf, renderer: DocumentRenderer = DocumentRenderer()) {
        window.isReleasedWhenClosed = false
        activeWindow = window
        preferences.layoutID = "a4Single"
        controller.start(preferences: preferences)
        model = DocumentViewModel(
            data: format == .pdf ? TestFixtures.pdf("Shortcuts", pages: 4) : Data("# Heading\n\nBody".utf8),
            fileURL: nil, format: format, preferences: preferences, library: UserLibrary(root: directory),
            renderer: renderer,
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        if format == .html { model.setHTMLPresentation(.paper, capturesWeb: false) }
        model.window = window
        model.printerListSource = { .init(names: ["Test Printer"], defaultName: "Test Printer") }
        model.printerCapabilitiesSource = { _ in nil }
        model.printSubmit = { [unowned self] _, request, _ in
            if !allowsPrint || !submissions.isEmpty { Issue.record("Unexpected print submission") }
            submissions.append(request)
        }
        model.outputOverride = { [unowned self] output, _ in
            if output != .exportPDF || !allowsExport || exports != 0 { Issue.record("Unexpected output") }
            exports += 1
        }
        model.manualDuplexSubmit = { _, _ in Issue.record("Unexpected manual duplex submission") }
        model.duplexTestSubmit = { _, _, _, _ in Issue.record("Unexpected duplex test submission") }
    }

    func event(
        _ text: String, flags: NSEvent.ModifierFlags = .command, code: UInt16 = 35,
        type: NSEvent.EventType = .keyDown, repeating: Bool = false, inWindow: Bool = true
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: inWindow ? window.windowNumber : 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: code)!
    }

    func release(_ code: UInt16 = 35) { _ = dispatcher.handle(event("p", code: code, type: .keyUp)) }

    func render() async throws {
        model.render()
        try await wait { !self.model.isRendering }
        try #require(model.error == nil)
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    func close() {
        dispatcher.stop()
        model.stop()
        hotKeys.stop()
        owner.close()
        suite.remove()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct ShortcutOutputBaselineTests {
    // Written before step 6 routing changes. Expectations come from the existing model/menu/view code.
    @Test("印刷は表示から刷り台へ入り、用紙を準備してから次の操作で一度だけ送る", .timeLimit(.minutes(1)))
    func contextualPrint() async throws {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        #expect(f.model.printCommand == .enterPrintMode)
        f.model.performPrintCommand()
        #expect(f.model.mode == .print)
        #expect(f.submissions.count == 0)
        try await f.render()
        try #require(f.model.canStartPrint)
        f.allowsPrint = true
        f.model.performPrintCommand()
        #expect(f.submissions.count == 1)
        #expect(f.submissions.first?.showsPanel == false)
        #expect(f.exports == 0)
    }

    @Test("六枚のカードは系列に従い、B判の六番だけA4の三ページとメモを選ぶ")
    func layoutCards() {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        let cases: [(PaperSeries, [String])] = [
            (.a, ["a4Single", "a4Duplex", "a3BookletA4", "a4BookletA5", "a3TwoUp", "a4Handout3"]),
            (.b, ["b5Single", "b5Duplex", "b4BookletB5", "b5BookletB6", "b4TwoUp", "a4Handout3"]),
            (
                .letter,
                [
                    "letterSingle", "letterDuplex", "tabloidBookletLetter", "letterBookletHalfLetter", "tabloidTwoUp",
                    "letterHandout3",
                ]
            ),
        ]
        for (series, expected) in cases {
            f.model.choosePaperSeries(series, remembers: false)
            for (index, id) in expected.enumerated() {
                f.model.chooseCard(at: index)
                #expect(f.model.layoutID == id)
                #expect(f.model.mode == .print)
            }
        }
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("拡大の両別名は文字サイズを変えず刷り台を1.25倍にし、見比べ台では何もしない", arguments: ["+", "="])
    func zoomAndComparison(symbol: String) {
        let f = ShortcutOutputFixture(format: .markdown)
        defer { f.close() }
        let zoomer = TrayZoomer()
        f.model.trayZoomer = zoomer
        f.model.enterCompareMode()
        #expect(f.model.mode == .compare)
        #expect(f.dispatcher.handle(f.event(symbol, code: 24)))
        #expect(zoomer.zoom == 1)
        #expect(f.model.textScale == 1)
        f.model.enterPrintMode()
        #expect(f.dispatcher.handle(f.event(symbol, code: 24)))
        #expect(zoomer.zoom == 1.25)
        #expect(f.model.textScale == 1)
        #expect(f.dispatcher.handle(f.event(symbol, flags: [.option, .command], code: 24)))
        #expect(f.model.textScale == 1.1)
        #expect(zoomer.zoom == 1.25)
        #expect(f.dispatcher.handle(f.event("-")))
        #expect(zoomer.zoom == 1)
        #expect(f.dispatcher.handle(f.event("0")))
        #expect(zoomer.zoom == 1)
        #expect(f.submissions.count == 0 && f.exports == 0)
    }

    @Test("刷り台のEscはポップオーバー、設定、折り見本、画面の順で固定する")
    func fixedEscape() {
        let f = ShortcutOutputFixture()
        defer { f.close() }
        f.model.enterPrintMode()
        #expect(f.model.printEscapeTarget == .screen)
        f.model.showsFold = true
        #expect(f.model.printEscapeTarget == .fold)
        f.model.isPrintFinishPresented = true
        #expect(f.model.printEscapeTarget == .settings)
        f.model.isPrintIssuesPresented = true
        #expect(f.model.printEscapeTarget == .popover)
        #expect(!f.dispatcher.handle(f.event("\u{1B}", flags: [], code: 53)))
        #expect(!f.dispatcher.handle(f.event("\r", flags: [], code: 36)))
        #expect(f.submissions.count == 0 && f.exports == 0)
    }
}
