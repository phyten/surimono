import AppKit
import Observation

/// AppKit-hosted windows do not participate in SwiftUI's scene focus propagation.
@Observable
final class DocumentWindows: NSObject {
    static let shared = DocumentWindows()
    private(set) weak var activeModel: DocumentViewModel?
    @ObservationIgnored private let models = NSMapTable<NSWindow, DocumentViewModel>.weakToWeakObjects()
    /// Where access to a file from outside the app waits for the file's window. Replaceable for tests.
    @ObservationIgnored var router: OpenRouter = .shared

    /// The windows' models that are still open; a window can only leave this table by going away.
    var openModels: [DocumentViewModel] { models.objectEnumerator()?.allObjects as? [DocumentViewModel] ?? [] }

    override private init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateActive), name: name, object: nil)
        }
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
