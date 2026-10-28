import AppKit
import Observation

/// AppKit-hosted windows do not participate in SwiftUI's scene focus propagation.
@Observable
final class DocumentWindows: NSObject {
    static let shared = DocumentWindows()
    private(set) weak var activeModel: DocumentViewModel?
    @ObservationIgnored private let models = NSMapTable<NSWindow, DocumentViewModel>.weakToWeakObjects()

    override private init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateActive), name: name, object: nil)
        }
    }

    func register(_ model: DocumentViewModel, for window: NSWindow) {
        models.setObject(model, forKey: window)
        updateActive()
    }

    @objc private func updateActive() {
        activeModel = NSApp.keyWindow.flatMap { models.object(forKey: $0) }
    }
}
