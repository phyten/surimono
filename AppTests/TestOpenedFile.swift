import AppKit

@testable import Surimono

extension OpenRouter.OpenedFile {
    /// Test opens can name their exact destination before their viewer registers.
    @MainActor
    static func testWindow(_ model: DocumentViewModel? = nil, reused: Bool = false) -> Self {
        let registration = DocumentWindows.Registration()
        if let model { registration.register(model) }
        return Self(destination: registration, wasAlreadyOpen: reused)
    }
}

@MainActor
final class TestFileWindow {
    let document = NSDocument()
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

    init(_ url: URL) {
        window.isReleasedWhenClosed = false
        document.fileURL = url
        document.addWindowController(NSWindowController(window: window))
    }

    func register(_ model: DocumentViewModel) {
        model.window = window
        DocumentWindows.shared.register(model, for: window)
    }

    func opened(reused: Bool = false) -> OpenRouter.OpenedFile {
        DocumentWindows.shared.opened(document, wasAlreadyOpen: reused)
    }
}
