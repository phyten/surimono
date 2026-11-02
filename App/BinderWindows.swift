import AppKit
import SwiftUI

final class BinderWindows {
    static let shared = BinderWindows()
    var preferences: AppPreferences?
    var library: UserLibrary?
    var settingsStore: DocumentSettingsStore?
    private var controllers: [UUID: MemoryDocumentWindowController] = [:]
    private var cascadePoint = NSPoint.zero

    var sourceURLs: [URL] { controllers.values.flatMap { $0.model.sourceURLs } }
    var hasWindows: Bool { !controllers.isEmpty }

    func open(_ urls: [URL], excluded: [URL] = []) {
        if let existing = controllers.values.first(where: { Set($0.model.sourceURLs) == Set(urls) }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let id = UUID()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            settingsStore: settingsStore, binder: BinderModel(urls: urls, excluded: excluded))
        model.isDrawerOpen = true
        let controller = MemoryDocumentWindowController(model: model) { [weak self] in
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
