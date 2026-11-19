import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// On the print screen, things open over one another; each Esc closes only the topmost, and the last leaves the screen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PrintEscapeOrderTests {
    /// What can be open together on the print screen, from the bottom up.
    enum Stack: String, CaseIterable, CustomTestStringConvertible {
        case settingsUnderPalette, foldUnderPalette, foldUnderProblems, foldUnderSettings
        var testDescription: String { rawValue }
    }

    @Test("印刷画面で重なって開いたものは、Esc を押すたびに上から 1 つずつ閉じ、最後の Esc で表示に戻る", arguments: Stack.allCases)
    func escapeClosesTheTopmostFirst(_ stack: Stack) async throws {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: TestFixtures.pdf("Body"))) })
        let model = DocumentViewModel(
            data: Data("# Heading\n\nBody".utf8), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory),
            renderer: renderer)
        model.specimenSamples.diskCache = ThemeSampleCache(directory: directory.appendingPathComponent("cache"))
        // Nothing here may reach a printer or a save panel.
        model.printSubmit = { _, _, _ in Issue.record("A print job was submitted") }
        model.outputOverride = { _, _ in Issue.record("An output was started") }
        // A booklet, which the tray can show folded.
        model.layoutID = PrintLayout.a4BookletA5.id
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer {
            model.themePaletteDidClose()
            model.isPrintIssuesPresented = false
            settle()
            controller.close()
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }
        let window = try #require(controller.window)
        controller.showWindow(nil)
        model.start()
        try await waitUntil { model.result != nil && !model.isRendering }
        model.enterPrintMode()
        try await waitUntil {
            model.mode == .print && model.hasCurrentPrintPreview && model.printTray?.isBooklet == true
        }
        try await Task.sleep(for: .milliseconds(500))

        // The layer underneath, then the one on top.
        let under: (isOpen: () -> Bool, name: String)
        switch stack {
        case .settingsUnderPalette:
            model.presentPrintSettings()
            under = ({ model.isPrintFinishPresented }, "settings")
        case .foldUnderPalette, .foldUnderProblems, .foldUnderSettings:
            model.showsFold = true
            under = ({ model.showsFold }, "fold")
        }
        try await Task.sleep(for: .milliseconds(300))
        let top: () -> Bool
        var popoverWindow: NSWindow?
        switch stack {
        case .settingsUnderPalette, .foldUnderPalette:
            model.openThemePalette()
            top = { model.isThemePalettePresented }
            popoverWindow = try await Self.popoverWindow(of: window)
        case .foldUnderProblems:
            model.isPrintIssuesPresented = true
            top = { model.isPrintIssuesPresented }
            popoverWindow = try await Self.popoverWindow(of: window)
        case .foldUnderSettings:
            model.presentPrintSettings()
            top = { model.isPrintFinishPresented }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(top() && under.isOpen())

        // A popover takes the keys while it is open; afterwards the document window does.
        try Self.pressEscape(in: popoverWindow ?? window)
        try await waitUntil("the first Esc to close the top") { !top() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(under.isOpen(), "The first Esc also closed the \(under.name)")
        #expect(model.mode == .print)

        try Self.pressEscape(in: window)
        try await waitUntil("the second Esc to close the \(under.name)") { !under.isOpen() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.mode == .print, "The second Esc also left the print screen")

        try Self.pressEscape(in: window)
        try await waitUntil("the third Esc to leave the print screen") { model.mode == .view }
        #expect(window.isVisible)
    }

    // MARK: Helpers

    private static func popoverWindow(of window: NSWindow) async throws -> NSWindow {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            if let popover = window.childWindows?.first(where: { $0.className.contains("Popover") && $0.isVisible }) {
                return popover
            }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The Esc key as AppKit delivers it: through the application, to the window and its first responder.
    private static func pressEscape(in window: NSWindow) throws {
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
    }

    private func waitUntil(_ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// SwiftUI may still lay out a popover's content after the popover closes, so the window outlives it a moment.
@MainActor
private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
}
