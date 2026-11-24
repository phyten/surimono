import AppKit
import SwiftUI

/// A closed window, its hosting view and copies of its root can all outlive the document.
final class DocumentWindowContent: NSObject {
    private final class Source {
        var model: DocumentViewModel?
        init(_ model: DocumentViewModel) { self.model = model }
    }

    private let source: Source
    var model: DocumentViewModel? { source.model }
    private weak var window: NSWindow?
    private let host: NSHostingController<Root>
    private var onEnd: ((_ closingWindow: Bool) -> Void)?

    private struct Root: View {
        let source: Source?
        let usesSnapshotAppearance: Bool

        @ViewBuilder var body: some View {
            if let model = source?.model {
                #if DEBUG
                    if usesSnapshotAppearance {
                        DocumentContent(model: model).snapshotControlAppearance()
                    } else {
                        DocumentContent(model: model)
                    }
                #else
                    DocumentContent(model: model)
                #endif
            }
        }
    }

    init(
        model: DocumentViewModel, in window: NSWindow, usesSnapshotAppearance: Bool = false,
        onEnd: ((_ closingWindow: Bool) -> Void)? = nil
    ) {
        let source = Source(model)
        self.source = source
        host = NSHostingController(rootView: Root(source: source, usesSnapshotAppearance: usesSnapshotAppearance))
        self.window = window
        self.onEnd = onEnd
        super.init()
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        model.window = window
        DocumentWindows.shared.register(model, for: window)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        center.addObserver(
            self, selector: #selector(terminate(_:)), name: NSApplication.willTerminateNotification, object: NSApp)
    }

    func close() { finish(closingWindow: true) }
    @objc private func windowWillClose(_ note: Notification) { close() }
    @objc private func terminate(_ note: Notification) { finish(closingWindow: false) }

    private func finish(closingWindow: Bool) {
        guard let model, !model.isWindowClosed else { return }
        NotificationCenter.default.removeObserver(self)
        let didEnd = onEnd
        onEnd = nil
        if let window { DocumentWindows.shared.unregister(window) }
        model.closeWindow()
        // A clipboard history entry reads the last paper size from the window.
        didEnd?(closingWindow)
        model.window = nil
        source.model = nil

        // The last window controller may already have left NSDocument.windowControllers. Keep the exact
        // host we installed through the next turn, outside SwiftUI's update and AppKit's close notification.
        DispatchQueue.main.async { [host, weak window] in
            host.rootView = Root(source: nil, usesSnapshotAppearance: false)
            let view = host.view
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            guard let window else { return }
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
                window.makeFirstResponder(nil)
            }
            if let responder = window.initialFirstResponder, responder.isDescendant(of: view) {
                window.initialFirstResponder = nil
            }
            if window.contentViewController === host { window.contentViewController = nil }
            if window.contentView === view { window.contentView = nil }
        }
    }
}
