import AppKit

@testable import Surimono

/// Own presentations from one clipboard router, including windows opened by a menu or a deferred answer.
@MainActor
final class ClipboardWindowFixture {
    private let router: ClipboardWindows
    private let originalPresentation: (MemoryDocumentWindowController) -> Void
    private var controllers: Set<MemoryDocumentWindowController> = []
    private var closeObserver: NSObjectProtocol?

    init(_ router: ClipboardWindows, ordered: Bool = false) {
        self.router = router
        originalPresentation = router.presentWindow
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let controller = window.windowController as? MemoryDocumentWindowController else { return }
                self?.controllers.remove(controller)
            }
        }
        router.presentWindow = { [weak self] controller in
            guard let self else { return }
            controllers.insert(controller)
            if ordered {
                // AppKit must order the window for tests of reopening, resizing and sheets.
                // Moving it beyond the desktop is temporary because the viewer fits it back to the screen.
                controller.window?.alphaValue = 0
                controller.window?.ignoresMouseEvents = true
                controller.window?.animationBehavior = .none
                originalPresentation(controller)
            }
        }
    }

    func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        router.presentWindow = originalPresentation
        for controller in controllers {
            controller.window?.orderOut(nil)
            controller.close()
        }
        controllers.removeAll()
    }
}
