import AppKit
import SurimonoCore
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

    @discardableResult
    func open(_ urls: [URL], excluded: [URL] = []) -> DocumentViewModel {
        open(urls, origin: .files) { BinderModel(urls: urls, excluded: excluded) }
    }

    /// A parent file's documents, with the parent's own text in front when it has any.
    @discardableResult
    func open(_ plan: MarkdownIncludes.Plan) -> DocumentViewModel {
        open(
            (plan.hasPreface ? [plan.parent] : []) + plan.documents,
            origin: .parent(plan.parent, hasPreface: plan.hasPreface, documents: plan.documents)
        ) { BinderModel(plan: plan) }
    }

    private func open(_ urls: [URL], origin: BinderModel.Origin, binder: () -> BinderModel) -> DocumentViewModel {
        // A preface reads differently from the same file on its own, so the same URLs can be two different binders. A
        // parent's plan names its binder, in its order: the window may since have been rearranged by hand, and stays
        // the one to come back to until the parent itself changes.
        let existing = controllers.values.first {
            guard $0.model.binder?.origin == origin else { return false }
            if case .parent = origin { return true }
            return Set($0.model.sourceURLs) == Set(urls)
        }
        if let existing {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing.model
        }
        let id = UUID()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            settingsStore: settingsStore, binder: binder())
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
        return model
    }
}
