import AppKit
import SurimonoCore

/// Marked's streaming preview: other apps put Markdown or HTML on a pasteboard of this name, and the one window shows it
/// as a document in memory. The pasteboard is looked at only while the window is open, and no file is made.
final class StreamingPreviewWindows {
    static let shared = StreamingPreviewWindows(closeWelcome: { WelcomeController.shared.close() })
    static let pasteboardName = NSPasteboard.Name("mkStreamingPreview")
    /// A pasteboard has no change notification; Marked's feeds send at a throttled pace, so this keeps up with them.
    static let pollInterval: TimeInterval = 0.5

    var preferences: AppPreferences?
    var library: UserLibrary?
    private(set) var controller: MemoryDocumentWindowController?
    private var board: NSPasteboard?
    private var timer: Timer?
    private var seenChangeCount = 0
    private var isWaiting = false
    private let closeWelcome: () -> Void

    var hasWindow: Bool { controller != nil }
    var isWatching: Bool { timer != nil }

    init(closeWelcome: @escaping () -> Void) {
        self.closeWelcome = closeWelcome
    }

    @discardableResult
    func open(from source: NSPasteboard? = nil) -> MemoryDocumentWindowController {
        let controller = controller ?? makeController(source ?? NSPasteboard(name: Self.pasteboardName))
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        closeWelcome()
        return controller
    }

    private func makeController(_ board: NSPasteboard) -> MemoryDocumentWindowController {
        self.board = board
        seenChangeCount = board.changeCount
        var data = Data()
        var format = DocumentFormat.markdown
        if case .document(let text, let kind) = ClipboardContent.streaming(text: board.string(forType: .string)) {
            data = text
            format = kind
        }
        // Each state of the feed would otherwise leave a record of its own; settings last as long as the window.
        let model = DocumentViewModel(
            data: data, fileURL: nil, format: format,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            title: String(localized: "Streaming Preview"))
        let controller = MemoryDocumentWindowController(model: model) { [weak self] in self?.windowDidClose() }
        self.controller = controller
        if data.isEmpty {
            isWaiting = true
            model.showToast(
                Toast(
                    systemImage: "dot.radiowaves.left.and.right",
                    title: String(localized: "Waiting for text from another app"),
                    detail: String(format: String(localized: "Pasteboard: %@"), Self.pasteboardName.rawValue)),
                dismissAfter: nil)
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return controller
    }

    /// Takes the pasteboard's latest state. While the pages are laid out the change stays unread, so that a fast feed
    /// shows its newest text next instead of cancelling every layout before it finishes.
    func poll() {
        guard let board, let model = controller?.model, board.changeCount != seenChangeCount, !model.isRendering
        else { return }
        // A writer clears the pasteboard first, which alone counts as the change: writing the text afterwards does not
        // change the count. So the change stays unread until there is text, or that text would never be seen.
        let changeCount = board.changeCount
        guard case .document(let data, let format) = ClipboardContent.streaming(text: board.string(forType: .string))
        else { return }
        seenChangeCount = changeCount
        if isWaiting {
            isWaiting = false
            model.dismissToast()
        }
        model.replaceContent(data, format: format)
    }

    private func windowDidClose() {
        timer?.invalidate()
        timer = nil
        board = nil
        controller = nil
        isWaiting = false
    }
}
