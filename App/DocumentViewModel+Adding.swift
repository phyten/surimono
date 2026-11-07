import AppKit
import SurimonoCore

/// The window a binder took the place of, to bring it back with Undo.
struct BinderOrigin {
    enum Contents {
        case document(URL)
        case images(ImageBundleModel.ListState)
    }

    let contents: Contents
    let frame: NSRect
    let pageIndex: Int
    let wasPrinting: Bool
}

extension DocumentViewModel {
    /// What this window can do with files brought to it. A document that failed to open has nothing to go on with.
    var dropReceiver: DropPlan.Receiver {
        if mode == .compare || error != nil && result == nil { return .closed(own: fileURL) }
        if let binder { return .binder(binder.urls) }
        if let imageBundle {
            return imageBundle.archiveURL == nil ? .imageBundle(imageBundle.urls) : .closed(own: fileURL)
        }
        return fileURL.map { .document($0) } ?? .closed(own: nil)
    }

    /// The Document menu's and the list's Add Documents…. Where nothing can be added the item stays, because a menu's
    /// state goes stale (see `DocumentCommands`), and says why instead.
    func chooseDocumentsToAdd() {
        if case .closed = dropReceiver {
            showToast(
                Toast(
                    systemImage: "info.circle", title: String(localized: "Documents cannot be added to this window"),
                    detail: cannotAddReason))
            return
        }
        presentAddPanel { [weak self] urls in self?.add(urls) }
    }

    private var cannotAddReason: String {
        if mode == .compare { return String(localized: "Go back to the view to add documents") }
        if imageBundle != nil { return String(localized: "The images of a ZIP archive stay as they are") }
        return String(localized: "A document without a file cannot join a binder")
    }

    /// Brings files to this window, as the plan for them says.
    func add(_ urls: [URL], at position: Int? = nil) {
        let plan = DropPlan(urls: urls, receiver: dropReceiver)
        switch plan.choice {
        case .joinOrOpen(let joining), .join(let joining): join(plan, joining, at: position)
        case .open: OpenRouter.shared.open(plan.others, from: window)
        case .refuse(let refusal):
            flashList(plan.alreadyIn)
            showToast(Toast(systemImage: "info.circle", title: DropCopy.refusal(refusal)))
        }
    }

    func join(_ plan: DropPlan, _ joining: DropPlan.Joining, at position: Int?) {
        switch joining {
        case .binder, .images:
            let excluded = newlyLeftOut(plan.leftOut)
            let added = addToList(plan.adding, excluded: excluded, at: position)
            flashList(added + plan.alreadyIn)
            guard !added.isEmpty else { return }
            registerUndoOfAdding(added, excluded: excluded, at: position)
        case .newBinder:
            BinderWindows.shared.turnIntoBinder(self, adding: plan.adding, leftOut: plan.leftOut)
        }
    }

    private func flashList(_ urls: [URL]) {
        binder?.flash(urls)
        imageBundle?.flash(urls)
    }

    /// What the list does not show as left out yet, which is all that going back may take away again.
    private func newlyLeftOut(_ urls: [URL]) -> [URL] {
        let shown = binder?.excludedURLs ?? imageBundle?.excludedPaths.map(URL.init(fileURLWithPath:)) ?? []
        return urls.filter { !shown.contains($0) }
    }

    @discardableResult
    private func addToList(_ urls: [URL], excluded: [URL], at position: Int?) -> [URL] {
        binder?.add(urls + excluded, at: position)
            ?? imageBundle?.add(urls, excluded: excluded, at: position) ?? []
    }

    private func registerUndoOfAdding(_ added: [URL], excluded: [URL], at position: Int?) {
        window?.undoManager?.registerUndo(withTarget: self) { model in
            model.binder?.undoAdding(added, excluded: excluded)
            model.imageBundle?.undoAdding(added, excluded: excluded)
            model.window?.undoManager?.registerUndo(withTarget: model) { model in
                model.addToList(added, excluded: excluded, at: position)
                model.registerUndoOfAdding(added, excluded: excluded, at: position)
            }
        }
        window?.undoManager?.setActionName(String(localized: "Add Documents"))
    }

    /// Takes a document off the list. It is one step of the same history as adding, so that going back never takes
    /// away what was added while the documents from before it are gone.
    func removeFromBinder(_ url: URL) {
        guard let binder, binder.items.count > 1, let index = binder.urls.firstIndex(of: url) else { return }
        let item = binder.items[index]
        binder.remove(url)
        window?.undoManager?.registerUndo(withTarget: self) { model in
            model.binder?.putBack(item, at: index)
            model.window?.undoManager?.registerUndo(withTarget: model) { $0.removeFromBinder(url) }
        }
        window?.undoManager?.setActionName(String(localized: "Remove from List"))
    }

    /// What a binder does not take over from this window, in the reader's words; nil when nothing is lost.
    var binderLossNote: String? {
        var names: [String] = []
        if isSmartRemovalEnabled { names.append(String(localized: "Smart Removal")) }
        if slideDeck != nil { names.append(String(localized: "Slide handling")) }
        if !paperChangeMarks.isEmpty { names.append(String(localized: "Change marks")) }
        if finishAppliesToText, printFinish != PrintFinish() {
            names.append(String(localized: "Page breaks and contents"))
        }
        if offersNotes, notes != NotePages() { names.append(String(localized: "Note pages")) }
        var lines: [String] = []
        if !names.isEmpty {
            lines.append(
                String(
                    format: String(localized: "%@ do not apply in a binder"),
                    ListFormatter.localizedString(byJoining: names)))
        }
        if showsWeb { lines.append(String(localized: "The page goes in as its file has it")) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    func undoBinderConversion() {
        guard let origin = binderOrigin, let window else { return }
        binderOrigin = nil
        dismissToast()
        switch origin.contents {
        case .document(let url):
            OpenRouter.shared.reopen(url, restoring: origin) { [weak self, weak window] opened in
                guard opened else { return }
                self?.isBinderUndone = true
                window?.close()
            }
        case .images(let state):
            let model = ImageBundleWindows.shared.open(
                OpenRequest.sorted(state.items.map(\.url)),
                excluded: state.excludedPaths.map(URL.init(fileURLWithPath:)))
            model.imageBundle?.restore(state)
            model.restoreWindow(origin)
            if origin.wasPrinting { model.requestPrintMode() }
            isBinderUndone = true
            window.close()
        }
    }
}

extension DocumentViewModel {
    /// Shows the panel for files to add. A ZIP cannot join anything, so it is not on offer.
    func presentAddPanel(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SurimonoDocument.readableContentTypes.filter { $0 != .zip }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { completion(panel.urls) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

extension DocumentViewModel {
    /// A drag came over the window. Returns whether dropping would do something.
    func dragEntered(_ urls: [URL], at point: CGPoint) -> Bool {
        let plan = DropPlan(urls: urls, receiver: dropReceiver)
        drop.begin(plan, rows: binder?.urls ?? imageBundle?.urls ?? [], at: point)
        guard case .refuse = plan.choice else { return true }
        flashList(plan.alreadyIn)
        return false
    }

    /// Does what the place under the pointer said it would.
    func performDrop() -> Bool {
        guard let plan = drop.plan, let zone = drop.zone else { return false }
        let position = drop.insertion
        switch (plan.choice, zone) {
        case (.joinOrOpen(let joining), .join), (.join(let joining), _): join(plan, joining, at: position)
        case (.joinOrOpen, .open), (.open, _): OpenRouter.shared.open(plan.others, from: window)
        case (.refuse, _): return false
        }
        return true
    }

    /// Whether what would open is in a window of its own already, which then only comes forward.
    func isOpenElsewhere(_ plan: DropPlan) -> Bool {
        guard case .single(let url) = plan.opening else { return false }
        return DocumentWindows.shared.openModels.contains { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
    }
}
