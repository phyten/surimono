import AppKit
import SurimonoCore
import SwiftUI

final class BinderWindows {
    static let shared = BinderWindows()
    var preferences: AppPreferences?
    var library: UserLibrary?
    var settingsStore: DocumentSettingsStore?
    var recentFiles = RecentBinderFiles()
    private var controllers: [UUID: MemoryDocumentWindowController] = [:]
    private var cascadePoint = NSPoint.zero
    /// Binders being laid out before their windows open.
    private(set) var pending: [DocumentViewModel] = []

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

    /// The binder of `urls`, whose window comes forward, when one is open.
    private func existing(_ urls: [URL], origin: BinderModel.Origin) -> MemoryDocumentWindowController? {
        // A preface reads differently from the same file on its own, so the same URLs can be two different binders. A
        // parent's plan names its binder, in its order: the window may since have been rearranged by hand, and stays
        // the one to come back to until the parent itself changes.
        controllers.values.first {
            guard $0.model.binder?.origin == origin else { return false }
            if case .parent = origin { return true }
            return Set($0.model.sourceURLs) == Set(urls)
        }
    }

    private func makeModel(_ binder: BinderModel) -> DocumentViewModel {
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .pdf,
            preferences: preferences ?? AppPreferences(), library: library ?? UserLibrary(),
            settingsStore: settingsStore, binder: binder)
        model.isDrawerOpen = true
        return model
    }

    @discardableResult
    private func makeController(for model: DocumentViewModel) -> MemoryDocumentWindowController {
        let id = UUID()
        let controller = MemoryDocumentWindowController(model: model) { [weak self] in
            self?.remember(model)
            self?.controllers.removeValue(forKey: id)
        }
        controllers[id] = controller
        return controller
    }

    /// Keeps a binder whose window is closing for the File menu's Recent Binders, so that the reader can open it again
    /// without choosing its files. One a parent file names comes back by opening the parent, and one document is no
    /// binder.
    func remember(_ model: DocumentViewModel) {
        guard let binder = model.binder, binder.origin == .files, binder.urls.count > 1 else { return }
        preferences?.recordRecentBinder(recentFiles.binder(of: binder.urls))
    }

    private func open(_ urls: [URL], origin: BinderModel.Origin, binder: () -> BinderModel) -> DocumentViewModel {
        if let existing = existing(urls, origin: origin) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing.model
        }
        let model = makeModel(binder())
        let controller = makeController(for: model)
        // Offset each new bundle like document windows instead of stacking it exactly over the previous one.
        if let window = controller.window { cascadePoint = window.cascadeTopLeft(from: cascadePoint) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        WelcomeController.shared.close()
        return model
    }

    /// Replaces the window of `source` with a binder of what it shows and `urls`. The window stays until the binder's
    /// pages are ready, so a failure leaves the reader where they were, and the children's folder access is held by
    /// the binder by then.
    func turnIntoBinder(_ source: DocumentViewModel, adding urls: [URL], leftOut: [URL]) {
        let order = source.sourceURLs + urls
        if let existing = existing(order, origin: .files) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        // One binder at a time for a set of files: another drop while it is laid out would make a second window of it.
        guard !source.isBecomingBinder, !pending.contains(where: { Set($0.sourceURLs) == Set(order) }) else { return }
        let model = makeModel(BinderModel(orderedURLs: order, excluded: leftOut))
        model.takeOver(from: source)
        source.isBecomingBinder = true
        model.onFirstRender = { [weak self, weak source, weak model] succeeded in
            guard let self, let model else { return }
            finishTurning(model, from: source, order: order, succeeded: succeeded)
        }
        pending.append(model)
        model.start()
    }

    private func finishTurning(
        _ model: DocumentViewModel, from source: DocumentViewModel?, order: [URL], succeeded: Bool
    ) {
        pending.removeAll { $0 === model }
        source?.isBecomingBinder = false
        // The reader may have closed the window meanwhile, or opened the same binder another way.
        if let source, source.window?.isVisible == true, succeeded, existing(order, origin: .files) == nil {
            present(model, replacing: source)
            return
        }
        if let source, source.window?.isVisible == true, !succeeded {
            source.showToast(
                Toast(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could not make the binder"), detail: model.error))
        }
        model.stop()
    }

    private func present(_ model: DocumentViewModel, replacing source: DocumentViewModel) {
        guard let sourceWindow = source.window else { return }
        let controller = makeController(for: model)
        guard let window = controller.window else { return }
        var frame = sourceWindow.frame
        if model.mode == .view, !source.showsSideList {
            // The paper stays where it is; the list takes the room beside it.
            frame.origin.x -= SidePanelMetrics.width
            frame.size.width += SidePanelMetrics.width
        }
        window.setFrame(frame, display: false)
        model.settleOnTray()
        let contents: BinderOrigin.Contents? =
            source.imageBundle.map { .images($0.listState) } ?? source.fileURL.map { .document($0) }
        model.binderOrigin = contents.map {
            BinderOrigin(
                contents: $0, frame: sourceWindow.frame, pageIndex: source.currentPageIndex,
                wasPrinting: source.mode == .print)
        }
        let note = source.binderLossNote
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        sourceWindow.close()
        model.showToast(
            Toast(
                systemImage: "books.vertical", title: String(localized: "Made a binder"), detail: note,
                action: .undoBinder),
            dismissAfter: .seconds(8))
        window.undoManager?.registerUndo(withTarget: model) { $0.undoBinderConversion() }
        window.undoManager?.setActionName(String(localized: "Make a Binder"))
    }
}
