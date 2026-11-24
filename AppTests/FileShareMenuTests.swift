import AppKit
import Testing

@testable import Surimono

@MainActor
struct FileShareMenuTests {
    @Test("共有を検証した後で窓を切り替えると新しい文書を選び、シートや文書のない窓からは送らない")
    func resolvesDocumentWhenInvoked() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = UserLibrary(root: root)
        let preferences = AppPreferences(defaults: suite.defaults)
        let previousKey = NSApp.keyWindow
        var windows: [NSWindow] = []
        var models: [DocumentViewModel] = []
        defer {
            for window in windows where window.attachedSheet != nil {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            for window in windows.reversed() { window.close() }
            for model in models { model.stop() }
            if let previousKey, previousKey.isVisible { previousKey.makeKeyAndOrderFront(nil) }
        }
        func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            return window
        }
        func document(_ url: URL?) -> (NSWindow, DocumentViewModel) {
            let model = DocumentViewModel(
                data: Data("Example".utf8), fileURL: url, format: .plainText, preferences: preferences, library: library
            )
            let window = makeWindow()
            model.window = window
            DocumentWindows.shared.register(model, for: window)
            models.append(model)
            return (window, model)
        }
        var recipients: [ObjectIdentifier] = []
        var contents: [FileShareMenu.Content] = []
        var selected: NSWindow?
        // In an inactive test host AppKit can keep keyWindow nil. The same dispatcher still checks
        // the real window, its attached sheet and the model registered for that window.
        let hasKeySession = NSApp.isActive
        let dispatcher = ShortcutDispatcher(
            controller: .shared, keyWindow: { hasKeySession ? NSApp.keyWindow : selected })
        func select(_ window: NSWindow) async throws {
            selected = window
            window.makeKeyAndOrderFront(nil)
            if hasKeySession {
                try await ShortcutMenuBaselineTests.waitForMenu { NSApp.keyWindow === window }
            }
        }
        let sharing = FileShareMenu(dispatcher: dispatcher) { model, content in
            recipients.append(ObjectIdentifier(model))
            contents.append(content)
        }
        let menu = NSMenu()
        menu.addItem(sharing.item)
        let action = try #require(sharing.item.action)
        func invoke() {
            // Target/action can still arrive after the validity check that enabled the row.
            _ = NSApp.sendAction(action, to: sharing.item.target, from: sharing.item)
        }
        let (a, _) = document(root.appendingPathComponent("a.txt"))
        let second = root.appendingPathComponent("b.txt")
        let (b, modelB) = document(second)
        let (clipboard, memory) = document(nil)
        try await select(a)
        menu.update()
        try #require(sharing.item.isEnabled)
        try await select(b)
        invoke()
        #expect(recipients == [ObjectIdentifier(modelB)])
        #expect(contents == [.files([second])])

        let sheet = makeWindow()
        b.beginSheet(sheet, completionHandler: nil)
        try #require(b.attachedSheet === sheet)
        invoke()
        #expect(contents == [.files([second])])
        b.endSheet(sheet)
        try await ShortcutMenuBaselineTests.waitForMenu { b.attachedSheet == nil }
        try await select(clipboard)
        invoke()
        let utility = makeWindow()
        try await select(utility)
        invoke()
        #expect(recipients == [ObjectIdentifier(modelB), ObjectIdentifier(memory)])
        #expect(contents == [.files([second]), .readingPDF])
    }
}
