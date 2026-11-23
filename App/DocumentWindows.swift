import AppKit
import Observation

/// AppKit-hosted windows do not participate in SwiftUI's scene focus propagation.
@Observable
final class DocumentWindows: NSObject {
    static let shared = DocumentWindows()
    private(set) weak var activeModel: DocumentViewModel?
    @ObservationIgnored private let models = NSMapTable<NSWindow, DocumentViewModel>.weakToWeakObjects()
    var currentModel: DocumentViewModel? {
        model(for: NSApp.keyWindow)
    }

    func model(for window: NSWindow?) -> DocumentViewModel? {
        window.flatMap { models.object(forKey: $0) }
    }

    /// Where access to a file from outside the app waits for the file's window. Replaceable for tests.
    @ObservationIgnored var router: OpenRouter = .shared

    /// A closed window can still be retained by its controller and must no longer receive file requests.
    var openModels: [DocumentViewModel] { models.objectEnumerator()?.allObjects as? [DocumentViewModel] ?? [] }

    override private init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateActive), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let model = models.object(forKey: window) else { return }
        models.removeObject(forKey: window)
        router.windowDidClose(model)
        updateActive()
    }

    /// Every kind of window registers its model here, so this reaches documents, bundles, binders and clipboard
    /// windows alike.
    func flushPendingSettings() {
        for model in openModels { model.flushPendingSettings() }
    }

    func register(_ model: DocumentViewModel, for window: NSWindow) {
        models.setObject(model, forKey: window)
        // The file may have finished opening before its window existed.
        router.handAccess(to: model)
        updateActive()
    }

    @objc private func updateActive() {
        activeModel = NSApp.keyWindow.flatMap { models.object(forKey: $0) }
    }
}
