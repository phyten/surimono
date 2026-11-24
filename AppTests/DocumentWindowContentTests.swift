import AppKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct DocumentWindowContentTests {
    @Test("選択行のクリックを監視するビューが残っても、解体時にコールバックを手放す")
    func dismantlingRowWatcherReleasesCallback() {
        let watcher = SelectedRowClicks.Watcher()
        weak var captured: NSObject?
        do {
            let owner = NSObject()
            captured = owner
            watcher.onClick = { [owner] _ in withExtendedLifetime(owner) {} }
        }
        #expect(captured != nil)
        SelectedRowClicks.dismantleNSView(watcher, coordinator: ())
        #expect(watcher.onClick == nil)
        #expect(captured == nil)
    }

    enum CloseSignal: CaseIterable {
        case close, willClose, willTerminate
    }

    @Test(
        "モデルを先に停止しても、閉じる要求・窓の通知・終了通知の全順序でホストを一度だけ片付ける",
        arguments: CloseSignal.allCases, [false, true])
    func closesHostOnce(first: CloseSignal, reverseRest: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Close"), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Never broadcast an application termination to the host app or other test windows.
        let center = NotificationCenter()
        var endings: [Bool] = []
        let content = DocumentWindowContent(model: model, in: window, notificationCenter: center) { closing in
            #expect(model.window === window)
            endings.append(closing)
        }
        defer { content.close() }
        let host = try #require(window.contentViewController)
        try #require(DocumentWindows.shared.model(for: window) === model)
        model.closeWindow()
        var rest = CloseSignal.allCases.filter { $0 != first }
        if reverseRest { rest.reverse() }
        for signal in [first] + rest {
            switch signal {
            case .close: content.close()
            case .willClose: center.post(name: NSWindow.willCloseNotification, object: window)
            case .willTerminate: center.post(name: NSApplication.willTerminateNotification, object: NSApp)
            }
            #expect(endings == [first != .willTerminate])
            #expect(content.model == nil)
            #expect(model.window == nil)
            #expect(DocumentWindows.shared.model(for: window) == nil)
        }
        try await ShortcutMenuBaselineTests.waitForMenu { window.contentViewController !== host }
    }
}
