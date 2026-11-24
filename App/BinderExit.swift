import AppKit
import Observation
import SurimonoCore

/// Owns the reader's decision, separately from list mutations and their undo history.
@Observable
final class BinderExit {
    struct Answer {
        let leave: Bool
        let suppress: Bool
    }

    var ask: (NSWindow, @escaping (Answer) -> Void) -> Void = { window, completion in
        precondition(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            "Hosted tests must inject BinderExit.ask before requesting a binder decision")
        let alert = NSAlert()
        alert.messageText = String(localized: "Only one document is left in this binder")
        alert.informativeText = String(localized: "Leave binder mode and show it as a single document?")
        alert.addButton(withTitle: String(localized: "Leave Binder Mode"))
        alert.addButton(withTitle: String(localized: "Keep as Binder")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        alert.beginSheetModal(for: window) { response in
            completion(
                Answer(leave: response == .alertFirstButtonReturn, suppress: alert.suppressionButton?.state == .on))
        }
    }
    var router: OpenRouter = .shared
    var openMemory: (Data, DocumentFormat, String) -> DocumentViewModel? = {
        ClipboardWindows.shared.open($0, format: $1, title: $2).model
    }
    var bringForward: (NSWindow) -> Void = {
        $0.deminiaturize(nil)
        $0.makeKeyAndOrderFront(nil)
    }
    private var asking = false
    private var opening = false
    private var removalPage: Int?
    private(set) var isClosed = false

    func cancel() { isClosed = true }

    func canLeave(_ model: DocumentViewModel) -> Bool {
        model.binder?.items.count == 1 && !opening && !asking && !isClosed
    }

    func readingSpot(in model: DocumentViewModel) -> BinderModel.ReadingSpot? {
        let page = model.mode == .print ? (model.binderTrayPageIndex ?? model.currentPageIndex) : model.currentPageIndex
        return model.binder?.readingSpot(at: page)
    }

    func removed(from model: DocumentViewModel, spot: BinderModel.ReadingSpot?) {
        guard canLeave(model), let item = model.binder?.items.first, let window = model.window else { return }
        removalPage = spot?.url == item.url ? spot?.page : 0
        switch model.preferences.singleDocumentBinderPolicy {
        case .stay: removalPage = nil
        case .leave: leave(model)
        case .ask:
            asking = true
            ask(window) { [weak self, weak model, weak window] answer in
                guard let self else { return }
                asking = false
                guard !isClosed, let model, let window, model.window === window,
                    model.binder?.items == [item]
                else {
                    removalPage = nil
                    return
                }
                model.preferences.singleDocumentBinderPolicy = .answer(
                    leaving: answer.leave, suppressing: answer.suppress)
                if answer.leave { leave(model) } else { removalPage = nil }
            }
        }
    }

    func leave(_ model: DocumentViewModel) {
        guard canLeave(model), let item = model.binder?.items.first, let window = model.window else { return }
        let page =
            removalPage ?? readingSpot(in: model).flatMap {
                $0.url == item.url ? $0.page : nil
            } ?? 0
        removalPage = nil
        let existing = router.openModels.first {
            guard $0 !== model, $0.binder == nil, $0.imageBundle == nil, $0.window != nil, !$0.binderExit.isClosed
            else { return false }
            if let memory = item.memory { return $0.memoryContent == memory.data && $0.format == item.format }
            return $0.fileURL?.standardizedFileURL == item.url.standardizedFileURL
        }
        if let existing, let target = existing.window {
            if model.mode == .print { existing.requestPrintMode() }
            bringForward(target)
            window.windowController?.close()
            return
        }
        let origin = BinderOrigin(
            contents: .document(item.url), frame: window.frame, pageIndex: page,
            wasPrinting: model.mode == .print, leavingBinder: true)
        if let memory = item.memory {
            guard let target = openMemory(memory.data, item.format, memory.title) else { return }
            target.restoreAfterLeavingBinder(origin)
            window.windowController?.close()
        } else {
            opening = true
            router.reopen(item.url, restoring: origin) { [weak self, weak window] opened in
                self?.opening = false
                if opened { window?.windowController?.close() }
            }
        }
    }
}
