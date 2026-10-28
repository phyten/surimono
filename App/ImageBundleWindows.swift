import AppKit
import SwiftUI

final class ImageBundleWindows {
    static let shared = ImageBundleWindows()
    var preferences: AppPreferences?
    var library: UserLibrary?
    private var controllers: [UUID: ImageBundleWindowController] = [:]
    private var cascadePoint = NSPoint.zero

    var sourceURLs: [URL] { controllers.values.flatMap { $0.model.sourceURLs } }
    var hasWindows: Bool { !controllers.isEmpty }

    func open(_ urls: [URL]) {
        let id = UUID()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            imageBundle: ImageBundleModel(urls: urls))
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

private final class ImageBundleWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: DocumentViewModel
    private let onClose: () -> Void
    private static let controls = NSToolbarItem.Identifier("documentControls")

    init(model: DocumentViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = model.imageBundle?.title(language: model.language) ?? "Surimono"
        let content = NSHostingController(rootView: DocumentContent(model: model))
        // By default the hosting controller shrinks the window to the content's ideal size, which leaves the preview
        // beside the thumbnails at its minimum. Only the minimum size should follow the content.
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1100, height: 760))
        super.init(window: window)
        model.window = window
        DocumentWindows.shared.register(model, for: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "ImageBundleToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.controls] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.controls] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let view = NSHostingView(rootView: BundleToolbar(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 670, height: 36)
        item.view = view
        return item
    }
}

private struct BundleToolbar: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        HStack(spacing: 12) {
            DocumentLayoutControls(model: model)
            DocumentPreviewControls(model: model)
            DocumentPrintButton(model: model)
        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .fixedSize()
        .preferredColorScheme(model.appearance.colorScheme)
    }
}
