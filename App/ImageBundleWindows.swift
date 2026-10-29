import AppKit
import SwiftUI

final class ImageBundleWindows {
    static let shared = ImageBundleWindows()
    var preferences: AppPreferences?
    var library: UserLibrary?
    var settingsStore: DocumentSettingsStore?
    private var controllers: [UUID: ImageBundleWindowController] = [:]
    private var cascadePoint = NSPoint.zero

    var sourceURLs: [URL] { controllers.values.flatMap { $0.model.sourceURLs } }
    var hasWindows: Bool { !controllers.isEmpty }

    func open(_ urls: [URL]) {
        let id = UUID()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            imageBundle: ImageBundleModel(urls: urls), settingsStore: settingsStore)
        let controller = ImageBundleWindowController(model: model) { [weak self] in
            self?.controllers.removeValue(forKey: id)
        }
        controllers[id] = controller
        // Offset each new bundle like document windows instead of stacking it exactly over the previous one.
        if let window = controller.window { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        WelcomeController.shared.close()
    }
}

private final class ImageBundleWindowController: NSWindowController, NSWindowDelegate {
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
        window.title = model.imageBundle?.title(language: model.language) ?? "Surimono"
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
