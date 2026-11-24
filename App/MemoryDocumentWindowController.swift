import AppKit
import SwiftUI

final class MemoryDocumentWindowController: NSWindowController {
    private let presentation: DocumentWindowContent
    var model: DocumentViewModel? { presentation.model }

    init(model: DocumentViewModel, onClose: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        ViewerWindow.configure(window)
        window.title = model.displayName
        presentation = DocumentWindowContent(model: model, in: window) { closingWindow in
            if closingWindow { onClose() }
        }
        window.setContentSize(NSSize(width: 760, height: 760))
        super.init(window: window)
        window.center()
    }

    override func close() {
        presentation.close()
        super.close()
    }

    required init?(coder: NSCoder) { nil }
}
