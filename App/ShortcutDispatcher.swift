import AppKit
import SurimonoCore

@MainActor
final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher(controller: .shared)
    let controller: ShortcutController
    let menus: SystemMenuShortcuts
    private let keyWindow: () -> NSWindow?
    private let firstResponder: (NSWindow) -> NSResponder?
    private let currentModel: () -> DocumentViewModel?
    private var monitor: Any?
    private var held: Set<UInt16> = []
    var openClipboardPrintScreen: () -> Void = { ClipboardWindows.shared.open(printing: true) }
    var executeOverride: ((ShortcutOperationID) -> Void)?

    init(
        controller: ShortcutController, menus: SystemMenuShortcuts? = nil,
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        model: (() -> DocumentViewModel?)? = nil,
        firstResponder: @escaping (NSWindow) -> NSResponder? = { $0.firstResponder }
    ) {
        let resolveModel = model ?? { DocumentWindows.shared.model(for: keyWindow()) }
        self.controller = controller
        self.menus = menus ?? SystemMenuShortcuts(controller: controller, keyWindow: keyWindow, model: resolveModel)
        self.keyWindow = keyWindow
        self.firstResponder = firstResponder
        currentModel = resolveModel

    }

    private var nativeMenuTracking: (() -> Int)?
    var trackingDepth: Int { nativeMenuTracking?() ?? menus.updates.trackingDepth }

    func start(nativeMenuTracking: (() -> Int)? = nil) {
        guard monitor == nil else { return }
        self.nativeMenuTracking = nativeMenuTracking
        if nativeMenuTracking == nil { menus.start() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = []
        if nativeMenuTracking == nil { menus.stop() }
        nativeMenuTracking = nil
    }

    func handle(_ event: NSEvent, fromMenu: Bool = false) -> Bool {
        if event.type == .keyUp {
            held.remove(event.keyCode)
            return false
        }
        guard event.type == .keyDown else { return false }
        // Menu tracking can report a windowless event to the monitor before invoking its item. Let the SwiftUI
        // action own that press; observing it here must not make its first invocation look like a hold.
        let window = keyWindow()
        guard fromMenu || event.window != nil || window == nil || trackingDepth == 0 else { return false }
        // Track even keys received during recording, typing or a sheet. Neither menu synchronization nor a mode/
        // window change proves the physical key was released. A missed key-up costs one press, never a print job.
        let wasHeld = !held.insert(event.keyCode).inserted
        guard !controller.hotKeys.isRecording else { return false }
        guard event.window === window || event.window == nil,
            window?.attachedSheet == nil, NSApp.modalWindow == nil,
            let combination = Self.combination(event, allowsBareKeys: true)
        else { return false }
        let responder = window.flatMap { firstResponder($0) }
        let model = modelForKeyWindow(window)
        let textInput = Self.isTextInput(responder)
        if textInput, !combination.modifiers.contains(.command) { return false }
        let visibility = MenuSnapshot.Visibility(model: model, preferences: menus.preferences())
        let matches = Self.operations.filter { operation in
            controller.localKeys(for: operation, textInput: textInput).contains(combination)
                && visibility.contains(operation)
                && isPresentedWhileTracking(operation)
        }
        if let input = responder as? NSTextInputClient, input.hasMarkedText() {
            // Keep recognized menu keys consumed during composition, as before surface routing existed.
            // Execute neither menu nor surface operations, and leave unmatched editing keys to the input client.
            return !matches.isEmpty
        }
        if let model, model.window === window, !model.blocksSurfaceShortcuts {
            if model.scrubber.dragging, combination == .init(key: .named(.escape)) {
                model.scrubber.cancel()
                return true
            }
            // Focus belongs to the track even if PDFKit still owns the native responder during the handoff.
            if combination.modifiers.isEmpty, case .named(let key) = combination.key, model.handleScrubKey(key) {
                return true
            }
            if let surface = ShortcutSurfaceKeys.owner(of: responder),
                (model.mode == .view && !model.showsWeb && surface.shortcutRegion != .foldedPreview)
                    || (model.mode == .print && model.showsFold && surface.shortcutRegion == .foldedPreview),
                let operation = ShortcutSurfaceKeys.match(event, region: surface.shortcutRegion, controller: controller)
            {
                if !Self.operations.contains(operation) || canPerform(operation, model: model) {
                    surface.performShortcut(operation, event: event)
                }
                return true
            }
            if model.shortcutListFocused, model.binder != nil, responder != nil,
                ShortcutSurfaceKeys.owner(of: responder) == nil,
                !Self.isTextInput(responder), !(responder is NSControl) || responder is NSTableView,
                ShortcutSurfaceKeys.match(event, region: .focusedList, controller: controller) == .listRemove
            {
                perform(.listRemove)
                return true
            }
        }
        if combination.modifiers.intersection([.command, .control]).isEmpty {
            guard let model, model.window === window, !model.blocksSurfaceShortcuts,
                let surface = ShortcutSurfaceKeys.owner(of: responder)
            else { return false }
            return Self.blocksNativePaperKey(combination, region: surface.shortcutRegion)
        }
        guard !matches.isEmpty else {
            // PDFKit also recognizes these keys. Do not revive a removed alias through a descendant responder.
            guard let model, model.window === window, !model.blocksSurfaceShortcuts,
                !Self.isTextInput(responder), !(responder is NSControl)
            else { return false }
            if let surface = ShortcutSurfaceKeys.owner(of: responder),
                Self.blocksNativePaperKey(combination, region: surface.shortcutRegion)
            {
                return true
            }
            return false
        }
        if Self.isTextInput(responder), matches.contains(where: { ShortcutOperation.operation($0).allowsBareKeys }) {
            return true
        }
        if window == nil && !matches.contains(where: { Self.isActive($0, model: nil) }) { return false }
        let activeMatches = matches.filter { canPerform($0, model: model) }
        guard activeMatches.count == 1, let operation = activeMatches.first
        else {
            return true
        }
        let safety = ShortcutOperation.operation(operation).safety
        if safety == .changesMode || safety == .printing || safety == .export {
            if event.isARepeat || wasHeld { return true }
        }
        perform(operation)
        return true
    }

    static func blocksNativePaperKey(_ key: ShortcutCombination, region: ShortcutRegion) -> Bool {
        if case .named(let named) = key.key {
            if region == .paperReading {
                return named.isArrow || [.space, .pageUp, .pageDown, .home, .end].contains(named)
            }
            if region == .foldedPreview { return named == .leftArrow || named == .rightArrow }
        }
        return key.modifiers.contains(.command)
            && ["=", "+", "-", "0"].contains { key.key == .character($0) }
    }

    static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextInputClient
    }

    static func combination(_ event: NSEvent, allowsBareKeys: Bool = false) -> ShortcutCombination? {
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard allowsBareKeys || !modifiers.intersection([.command, .control]).isEmpty else { return nil }
        if event.modifierFlags.contains(.function) {
            guard let named = ShortcutKeyboardLayout.special[event.keyCode],
                ShortcutMenuKey.character(.named(named)) == text
            else { return nil }
        }
        let named = ShortcutMenuKey.named(text)
        return try? ShortcutCombination(key: named.map(ShortcutKey.named) ?? .character(text), modifiers: modifiers)
            .normalized()
    }

    static func isActive(_ operation: ShortcutOperationID, model: DocumentViewModel?) -> Bool {
        isActive(operation, in: region(for: model))
    }

    static func region(for model: DocumentViewModel?) -> ShortcutRegion? {
        guard let model else { return nil }
        switch model.mode {
        case .view: return model.showsWeb ? .web : .paperReading
        case .print: return model.showsFold ? .foldedPreview : .printSheet
        case .compare: return .comparison
        }
    }

    static func isActive(_ operation: ShortcutOperationID, in region: ShortcutRegion?) -> Bool {
        let metadata = ShortcutOperation.operation(operation)
        if metadata.applicability == .application || operation == .appCheckUpdates { return true }
        guard let region else { return false }
        return metadata.regions.contains(region)
    }

    static func isAvailable(
        _ operation: ShortcutOperationID, model: DocumentViewModel?, visibility: MenuSnapshot.Visibility
    ) -> Bool {
        guard visibility.contains(operation) else { return false }
        if operation == .viewOptions { return model?.mode == .view }
        if operation == .viewSelectText { return model?.canSelectText == true }
        if operation == .listRemove { return model?.binder?.selection != nil && (model?.binder?.items.count ?? 0) > 1 }
        guard isActive(operation, model: model) else { return false }
        guard let model else { return true }
        switch operation {
        case .documentPrint: return model.canPerformPrintCommand
        case .documentPrintSystem: return model.canRequestPrint
        case .documentExportPDF: return model.canRequestSheetOutput
        case .documentExportReadingPDF: return model.canRequestReadingPDF
        case .documentExportHTML, .documentCopyHTML, .documentCopyRichText: return model.canExportReading(.html)
        case .documentExportPNG, .documentShare: return model.canExportReading(.png)
        case .documentGoToPage: return model.canGoToPage
        case .documentFind, .documentFindNext, .documentFindPrevious: return model.hasPaperToSearch
        case .viewHtmlPresentation: return model.mode == .view && model.usesHTMLPresentation
        case .viewIgnoreSlides: return model.detectedSlideDeck != nil
        case .styleCompare: return model.mode == .view && model.usesPrintTheme
        case .compareShuffle: return model.usesPrintTheme && model.themeComparison != nil
        case .styleChoose, .styleFavorite, .textIncrease, .textDecrease, .textReset:
            return model.usesPrintTheme
        case .readingBack: return model.canNavigateReading && model.pageHistory.canGoBack
        case .readingForward: return model.canNavigateReading && model.pageHistory.canGoForward
        case .bookmarkToggle: return model.canNavigateReading
        case .bookmarkNext: return model.nextBookmark != nil
        case .bookmarkPrevious: return model.previousBookmark != nil
        case .viewOutline: return model.hasContents
        case .viewDocumentInfo: return !model.showsWeb
        case .documentAdd:
            if case .closed = model.dropReceiver { return false }
            return true
        case .listMoveUp, .listMoveDown:
            let offset = operation == .listMoveUp ? -1 : 1
            return model.imageBundle?.canMoveSelection(by: offset) == true
                || model.binder?.canMoveSelection(by: offset) == true
        case .listSortByName: return model.imageBundle?.isSortedByName == false || model.binder?.isSortedByName == false
        case .printFoldPreview: return model.layout.kind == .booklet
        case .printReviewIssues: return !model.printIssues.isEmpty
        case .htmlSmartRemoval: return model.format == .html
        case .htmlReviewRemoval: return model.format == .html && model.isSmartRemovalEnabled
        case .printManualDuplex: return model.canPrintManualDuplex
        case .printDuplexTest: return model.canPrintDuplexTest
        default: return true
        }
    }

    static let operations = SystemMenuShortcuts.operations.union(ShortcutCommands.operations)

    /// Menu tracking may bypass a local monitor. Recheck the event through the same key-up gate; mouse clicks
    /// remain ordinary commands. A stale SwiftUI equivalent can never resurrect a cleared output binding.
    func performFromMenu(_ operation: ShortcutOperationID, event: NSEvent?) {
        if let event, event.type == .keyDown, let key = Self.combination(event) {
            guard controller.localKeys(for: operation).contains(key) else { return }
            _ = handle(event, fromMenu: true)
        } else {
            // Return/Space confirming a focused menu item are fixed native activation, not an assigned equivalent.
            perform(operation)
        }
    }

    private func isPresentedWhileTracking(_ operation: ShortcutOperationID) -> Bool {
        trackingDepth == 0 || menus.menuState.snapshot.content.visibility.contains(operation)
    }

    private func modelForKeyWindow(_ window: NSWindow?) -> DocumentViewModel? {
        guard let window, let model = currentModel(), model.window === window else { return nil }
        return model
    }

    private func canPerform(_ operation: ShortcutOperationID, model: DocumentViewModel?) -> Bool {
        guard Self.operations.contains(operation), !controller.hotKeys.isRecording,
            NSApp.modalWindow == nil, keyWindow()?.attachedSheet == nil
        else { return false }
        if let window = keyWindow(), let input = firstResponder(window) as? NSTextInputClient, input.hasMarkedText() {
            return false
        }
        return isPresentedWhileTracking(operation)
            && Self.isAvailable(
                operation, model: model, visibility: .init(model: model, preferences: menus.preferences()))
    }

    func perform(_ operation: ShortcutOperationID) {
        let model = modelForKeyWindow(keyWindow())
        guard canPerform(operation, model: model) else { return }
        if let executeOverride {
            executeOverride(operation)
            return
        }
        if let model, let layout = ShortcutPrintLayouts.layout(for: operation, series: model.trayPaperSeries) {
            model.chooseLayout(layout.id)
            return
        }
        if ShortcutCommands.operations.contains(operation) {
            model?.performAdditionalShortcut(operation)
            return
        }
        switch operation {
        case .documentPrint: model?.performPrintCommand()
        case .documentPrintSystem: model?.printDocument(quick: false)
        case .documentExportPDF: model?.exportPDF()
        case .documentExportReadingPDF: model?.exportReadingPDF()
        case .documentExportPNG: model?.exportReading(.png)
        case .documentExportHTML: model?.exportReading(.html)
        case .documentCopyHTML: model?.exportReading(.htmlText)
        case .documentCopyRichText: model?.exportReading(.richText)
        case .documentShare: model?.exportReading(.share)
        case .printSettings: model?.presentPrintSettings()
        case .clipboardOpenPrintScreen: openClipboardPrintScreen()
        case .appOpen: OpenRouter.shared.showOpenPanel()
        case .appSettings: menus.showSettings()
        case .appOpenURL: OpenURLPanel.present()
        case .clipboardReopen: ClipboardWindows.shared.reopenClosed()
        case .clipboardOpen: ClipboardWindows.shared.open()
        case .appStreamingPreview: StreamingPreviewWindows.shared.open()
        case .appGettingStarted: OpenRouter.shared.openGettingStarted()
        case .appKeyGuide: KeyGuideWindow.shared.show()
        case .appCheckUpdates:
            if AppUpdater.shared.isAvailable { AppUpdater.shared.checkForUpdates() }
        case .settingSetManage:
            if let preferences = WelcomeController.shared.preferences {
                BandArrangementEditorSession.showSection(.settingSets, preferences: preferences)
            }
            menus.showSettings()
        case .documentFind: model?.performFind()
        case .documentFindNext: model?.findStep(forward: true)
        case .documentFindPrevious: model?.findStep(forward: false)
        case .documentGoToPage: model?.presentGoToPage()
        case .readingBack: model?.goBack()
        case .readingForward: model?.goForward()
        case .bookmarkToggle: model?.toggleBookmark()
        case .bookmarkNext: model?.goToNextBookmark()
        case .bookmarkPrevious: model?.goToPreviousBookmark()
        case .documentReload: model?.reload()
        case .documentSaveAsFile: model?.saveAsFile()
        case .documentAdd: model?.chooseDocumentsToAdd()
        case .documentOpenBinder: model?.openIncludesAsBinder()
        case .documentResetSettings: model?.resetDocumentSettings()
        case .viewOptions: model?.isViewOptionsPresented = true
        case .viewSelectText: model?.toggleSelectingText()
        case .listRemove:
            if let url = model?.binder?.selection { model?.removeFromBinder(url) }
        case .viewHtmlPresentation: model?.toggleHTMLPresentation()
        case .viewIgnoreSlides: model?.toggleShowsSlides()
        case .textIncrease: model?.increaseTextSize()
        case .textDecrease: model?.decreaseTextSize()
        case .textReset: model?.resetTextSize()
        case .viewZoomIn:
            if model?.mode != .compare { model?.zoomIn() }
        case .viewZoomOut:
            if model?.mode != .compare { model?.zoomOut() }
        case .viewZoomFit:
            if model?.mode != .compare { model?.zoomToFit() }
        case .viewSingle: model?.setLayout(.single)
        case .viewSpread: model?.setLayout(.spread)
        case .viewToolbarAlways:
            if let model { model.isBandAlwaysVisible.toggle() }
        case .viewFloatOnTop:
            if let model { model.isAlwaysOnTop.toggle() }
        case .viewShowOnAllSpaces:
            if let model { model.showsOnAllSpaces.toggle() }
        case .styleChoose: model?.openThemePalette()
        case .settingSetSave:
            if let model { SettingSetDialogs.save(model) }
        case .listToggle:
            if let model, model.binder != nil || model.imageBundle != nil { model.setSideListOpen(!model.isDrawerOpen) }
        case .listMoveUp:
            model?.imageBundle?.moveSelection(by: -1)
            model?.binder?.moveSelection(by: -1)
        case .listMoveDown:
            model?.imageBundle?.moveSelection(by: 1)
            model?.binder?.moveSelection(by: 1)
        case .listSortByName:
            model?.imageBundle?.sortByName()
            model?.binder?.sortByName()
        case .binderOddPageStarts:
            if let model, model.binder != nil { model.binderStartsOnFront.toggle() }
        default: break
        }
    }
}
