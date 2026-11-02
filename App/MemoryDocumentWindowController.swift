import AppKit
import SwiftUI

final class MemoryDocumentWindowController: NSWindowController, NSWindowDelegate {
    let model: DocumentViewModel
    private let onClose: () -> Void

    init(model: DocumentViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        ViewerWindow.configure(window)
        window.title = model.displayName
        let content = NSHostingController(rootView: DocumentContent(model: model))
        // By default the hosting controller resizes the window to the content's ideal size; the paper decides it.
        content.sizingOptions = []
        // Lets the print mode's toolbar reach this window, as it does in document windows.
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 760, height: 760))
        super.init(window: window)
        model.window = window
        DocumentWindows.shared.register(model, for: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose()
    }
}
