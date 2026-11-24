import AppKit
import Observation

/// Maps the current key window to its document. Utility windows intentionally resolve to nil.
@Observable
final class DocumentWindows: NSObject {
    static let shared = DocumentWindows()
    // Keep the last observed value until the next key-window notification, including the final close.
    private(set) var activeModel: DocumentViewModel?
    @ObservationIgnored private let models = NSMapTable<NSWindow, DocumentViewModel>.weakToWeakObjects()
    var currentModel: DocumentViewModel? {
        model(for: NSApp.keyWindow)
    }

    func model(for window: NSWindow?) -> DocumentViewModel? {
        window.flatMap { models.object(forKey: $0) }
    }

    /// Where access to a file from outside the app waits for the file's window. Replaceable for tests.
    @ObservationIgnored var router: OpenRouter = .shared

    /// The models whose windows are still open.
    var openModels: [DocumentViewModel] { models.objectEnumerator()?.allObjects as? [DocumentViewModel] ?? [] }

    override private init() {
        super.init()
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: name, object: nil)
        }
    }

    /// Every kind of window registers its model here, so this reaches documents, bundles, binders and clipboard
    /// windows alike.
    func flushPendingSettings() {
        for model in openModels { model.flushPendingSettings() }
    }

    func register(_ model: DocumentViewModel, for window: NSWindow) {
        guard !model.isWindowClosed else { return }
        models.setObject(model, forKey: window)
        #if DEBUG
            DebugMenuDump.documentRegistered()
        #endif
        // The file may have finished opening before its window existed.
        router.handAccess(to: model)
        updateActive()
    }

    func unregister(_ window: NSWindow) {
        models.removeObject(forKey: window)
        updateActive()
    }

    @objc private func keyWindowChanged() {
        // AppKit can still return the old key window during resign/close notification delivery.
        DispatchQueue.main.async { self.updateActive() }
    }

    private func updateActive() {
        let current = currentModel
        if activeModel !== current { activeModel = current }
    }
}
