import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// The × at the right end of every popover's heading row, and Esc.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PopoverCloseControlTests {
    // MARK: A popover of its own

    @Test("見えている × をマウスで押すと吹き出しが閉じる")
    func clickingTheButtonCloses() async throws {
        let host = TestPopoverHost.open()
        defer { host.close() }
        let popoverWindow = try await host.popoverWindow()
        try await waitUntil {
            host.state.closeProbe?.window === popoverWindow && host.state.closeProbe?.bounds.isEmpty == false
        }
        let probe = try #require(host.state.closeProbe)
        let rect = probe.convert(probe.bounds, to: nil)
        try TestWindowMouse.click(at: CGPoint(x: rect.midX, y: rect.midY), in: popoverWindow)
        try await waitUntil { !host.state.isPresented }
    }

    @Test("× があっても、開いたときのフォーカスは吹き出しの入力欄に入る")
    func keepsTheFieldsFocus() async throws {
        let host = TestPopoverHost.open()
        defer { host.close() }
        let popoverWindow = try await host.popoverWindow()
        try await waitUntil { !PopoverCloseButton.dismissActions(in: popoverWindow).isEmpty }
        let editor = try #require(popoverWindow.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(host.state.isPresented)
    }

    @Test("入力欄にフォーカスがあるとき、Esc キーを押すと吹き出しが閉じる")
    func escapeKeyCloses() async throws {
        let host = TestPopoverHost.open()
        defer { host.close() }
        let popoverWindow = try await host.popoverWindow()
        try await waitUntil { !PopoverCloseButton.dismissActions(in: popoverWindow).isEmpty }
        #expect(popoverWindow.firstResponder is NSTextView)

        try TestWindowKeyboard.pressEscape(in: popoverWindow)
        try await waitUntil { !host.state.isPresented }
    }

    @Test("× の説明「Close (Esc)」は 8 言語に訳があり、どの言語でも Esc のキーを示す")
    func helpIsTranslated() throws {
        let keys = [
            "en": "Esc", "ja": "Esc", "zh-Hans": "Esc", "zh-Hant": "Esc", "ko": "Esc", "fr": "Échap", "de": "Esc",
            "es": "Esc",
        ]
        for (language, key) in keys {
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            let help = bundle.localizedString(forKey: "Close (Esc)", value: "MISSING", table: nil)
            let close = bundle.localizedString(forKey: "Close", value: "MISSING", table: nil)
            #expect(help.contains(key), "\(language)")
            #expect(help.contains(close), "\(language)")
        }
    }

    // MARK: The app's popovers

    enum AppPopover: String, CaseIterable, CustomTestStringConvertible {
        case viewOptions, outline, figures, stylePalette, printSettings, printIssues, comparePlace
        var testDescription: String { rawValue }
    }

    @Test("アプリの吹き出しには、どれも × がちょうど 1 つあり、その閉じる動作で吹き出しの表示の状態が戻る", arguments: AppPopover.allCases)
    func dismissActionClearsThePresentation(_ popover: AppPopover) async throws {
        let screen = try await AppPopoverScreen.open(popover)
        defer { screen.close() }
        let actions = PopoverCloseButton.dismissActions(in: screen.popoverWindow)
        #expect(actions.count == 1)
        let dismiss = try #require(actions.first)
        dismiss()
        try await waitUntil { !screen.isPresented() }
    }

    @Test("アプリの吹き出しは、どれも Esc キーで閉じる", arguments: AppPopover.allCases)
    func escapeKeyClosesTheAppPopover(_ popover: AppPopover) async throws {
        let screen = try await AppPopoverScreen.open(popover)
        defer { screen.close() }
        try TestWindowKeyboard.pressEscape(in: screen.popoverWindow)
        try await waitUntil { !screen.isPresented() }
    }

    @Test(
        "印刷画面と見比べ台では、1 回目の Esc は吹き出しだけを閉じて画面に残り、2 回目の Esc で表示に戻る",
        arguments: [AppPopover.printIssues, .comparePlace])
    func firstEscapeClosesOnlyThePopover(_ popover: AppPopover) async throws {
        let screen = try await AppPopoverScreen.open(popover)
        defer { screen.close() }
        let mode = screen.model.mode
        #expect(mode == (popover == .printIssues ? .print : .compare))

        try TestWindowKeyboard.pressEscape(in: screen.popoverWindow)
        try await waitUntil { !screen.isPresented() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(screen.model.mode == mode)
        #expect(screen.window.isVisible)

        try TestWindowKeyboard.pressEscape(in: screen.window)
        try await waitUntil { screen.model.mode == .view }
        #expect(screen.window.isVisible)
    }

    @Test("見比べ台の箇所の一覧では、見えている × をマウスで押すと、選んだ箇所を変えずに閉じる")
    func clickingTheComparePlaceButtonCloses() async throws {
        let screen = try await AppPopoverScreen.open(.comparePlace)
        defer { screen.close() }
        let place = try #require(screen.model.comparePlace)
        let popoverWindow = screen.popoverWindow
        // The list is 320pt wide, and the popover's window reaches as far past it on every side. The × lies 6pt in
        // from the list's right edge and on the middle of its 30pt first row, which starts 6pt down.
        let margin = (popoverWindow.frame.width - 320) / 2
        let point = NSPoint(
            x: popoverWindow.frame.width - margin - 6 - 11, y: popoverWindow.frame.height - margin - 6 - 15)

        try TestWindowMouse.click(at: point, in: popoverWindow)
        try await waitUntil { !screen.isPresented() }
        #expect(screen.model.comparePlace == place)
        #expect(screen.model.mode == .compare)
    }

    // MARK: Helpers

    static func popoverWindow(of window: NSWindow) async throws -> NSWindow {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if let popover = window.childWindows?.first(where: { $0.className.contains("Popover") && $0.isVisible }) {
                return popover
            }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A native button can run its own mouse-tracking loop synchronously inside mouseDown.
@MainActor
enum TestWindowMouse {
    static func click(at point: NSPoint, in window: NSWindow) throws {
        func event(_ type: NSEvent.EventType, pressure: Float) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: pressure))
        }
        if #available(macOS 26, *) {
            // Application dispatch delivers the pair to the numbered window even while the test host is inactive.
            NSApp.sendEvent(try event(.leftMouseDown, pressure: 1))
            NSApp.sendEvent(try event(.leftMouseUp, pressure: 1))
            return
        }
        // Sequoia can enter a synchronous tracking loop in mouseDown and needs the matching up already queued.
        var root = window.contentView
        while let parent = root?.superview { root = parent }
        let hit = root.flatMap { $0.hitTest($0.convert(point, from: nil)) }
        print(
            "test click: window=\(window.windowNumber) point=\(point) hit=\(String(describing: hit.map { type(of: $0) }))"
        )
        let down = try event(.leftMouseDown, pressure: 1)
        window.postEvent(try event(.leftMouseUp, pressure: 0), atStart: true)
        NSApp.sendEvent(down)
        print("test click: mouseDown returned")
    }
}

/// A document window, as the app opens one, with one of its popovers open.
@MainActor
private struct AppPopoverScreen {
    let model: DocumentViewModel
    let controller: MemoryDocumentWindowController
    let window: NSWindow
    let popoverWindow: NSWindow
    let isPresented: () -> Bool
    let directory: URL
    let suite: TestDefaultsSuite

    static func open(_ popover: PopoverCloseControlTests.AppPopover) async throws -> AppPopoverScreen {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: TestFixtures.pdf("Body"))) })
        let model = DocumentViewModel(
            data: Data("# Heading\n\nBody\n\n## Second\n\nMore".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        model.specimenSamples.diskCache = ThemeSampleCache(directory: directory.appendingPathComponent("cache"))
        // Nothing here may reach a printer or a save panel.
        model.printSubmit = { _, _, _ in Issue.record("A print job was submitted") }
        model.outputOverride = { _, _ in Issue.record("An output was started") }
        model.bandVisibility = .always
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        var handedOff = false
        defer {
            if !handedOff {
                model.closeAllPopovers()
                controller.close()
                try? FileManager.default.removeItem(at: directory)
                suite.remove()
            }
        }
        let window = try #require(controller.window)
        controller.showWindow(nil)
        model.start()
        try await wait { model.result != nil && !model.isRendering }
        switch popover {
        case .printIssues:
            model.enterPrintMode()
            try await wait { model.mode == .print && model.isUpToDate }
        case .comparePlace:
            model.enterCompareMode()
            await model.followComparePlaces()
            try await wait { model.mode == .compare && !model.themeSamples.places.isEmpty }
            // A place other than the first page, to tell the × from the list's first row.
            model.comparePlace = model.themeSamples.places.last
        default: break
        }
        try await Task.sleep(for: .milliseconds(500))
        let isPresented: () -> Bool
        switch popover {
        case .viewOptions:
            model.isViewOptionsPresented = true
            isPresented = { model.isViewOptionsPresented }
        case .outline:
            model.isOutlinePresented = true
            isPresented = { model.isOutlinePresented }
        case .figures:
            model.isFiguresPresented = true
            isPresented = { model.isFiguresPresented }
        case .stylePalette:
            model.openThemePalette()
            isPresented = { model.isThemePalettePresented }
        case .printSettings:
            model.presentPrintSettings()
            isPresented = { model.isPrintFinishPresented }
        case .printIssues:
            model.isPrintIssuesPresented = true
            isPresented = { model.isPrintIssuesPresented }
        case .comparePlace:
            model.isComparePlacePickerPresented = true
            isPresented = { model.isComparePlacePickerPresented }
        }
        let popoverWindow = try await PopoverCloseControlTests.popoverWindow(of: window)
        try await wait { !PopoverCloseButton.dismissActions(in: popoverWindow).isEmpty }
        // Give a second × the time to appear, so that "exactly one" means something.
        try await Task.sleep(for: .milliseconds(200))
        handedOff = true
        return AppPopoverScreen(
            model: model, controller: controller, window: window, popoverWindow: popoverWindow,
            isPresented: isPresented, directory: directory, suite: suite)
    }

    func close() {
        model.closeAllPopovers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        controller.close()
        try? FileManager.default.removeItem(at: directory)
        suite.remove()
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// The app target isolates its types to the main actor by default; this target does not, and Xcode 26.6 does not
// infer the isolation for an extension written here.
@MainActor
extension DocumentViewModel {
    fileprivate func closeAllPopovers() {
        isViewOptionsPresented = false
        isOutlinePresented = false
        isFiguresPresented = false
        themePaletteDidClose()
        isPrintFinishPresented = false
        isPrintIssuesPresented = false
        isComparePlacePickerPresented = false
    }
}

@MainActor
@Observable
private final class TestPopoverState {
    var isPresented = true
    var text = ""
    @ObservationIgnored weak var closeProbe: NSView?
}

private struct CloseButtonProbe: NSViewRepresentable {
    let state: TestPopoverState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        state.closeProbe = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// A heading row with the ×, and a text field under it, as the view options and the style palette have.
private struct TestPopoverRoot: View {
    @Bindable var state: TestPopoverState

    var body: some View {
        Color.gray
            .popover(isPresented: $state.isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading) {
                    HStack {
                        Text(verbatim: "Popover")
                        Spacer(minLength: 0)
                        PopoverCloseButton()
                            .background { CloseButtonProbe(state: state).allowsHitTesting(false) }
                    }
                    TextField(text: $state.text) { Text(verbatim: "Field") }
                }
                .padding(16)
                .frame(width: 240)
            }
    }
}

@MainActor
private final class TestPopoverHost {
    let window: NSWindow
    let state = TestPopoverState()
    /// SwiftUI may still lay out an open popover's content after its window closes, so the popover closes first and
    /// the host outlives the test.
    private static var retained: [TestPopoverHost] = []

    private init() {
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 200, width: 360, height: 300), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    static func open() -> TestPopoverHost {
        let host = TestPopoverHost()
        host.window.contentView = NSHostingView(rootView: TestPopoverRoot(state: host.state))
        host.window.makeKeyAndOrderFront(nil)
        return host
    }

    func popoverWindow() async throws -> NSWindow {
        try await PopoverCloseControlTests.popoverWindow(of: window)
    }

    func close() {
        Self.retained.append(self)
        state.isPresented = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        window.close()
    }
}
