import AppKit
import SurimonoCore

@MainActor
final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher(controller: .shared)
    let controller: ShortcutController
    let bridge: ShortcutMenuBridge
    private let keyWindow: () -> NSWindow?
    private let firstResponder: (NSWindow) -> NSResponder?
    private let currentModel: () -> DocumentViewModel?
    private var monitor: Any?
    private var held: Set<UInt16> = []
    var openClipboardPrintScreen: () -> Void = { ClipboardWindows.shared.open(printing: true) }
    var executeOverride: ((ShortcutOperationID) -> Void)?

    init(
        controller: ShortcutController, bridge: ShortcutMenuBridge? = nil,
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        model: (() -> DocumentViewModel?)? = nil,
        firstResponder: @escaping (NSWindow) -> NSResponder? = { $0.firstResponder }
    ) {
        let resolveModel = model ?? { DocumentWindows.shared.model(for: keyWindow()) }
        self.controller = controller
        self.bridge = bridge ?? ShortcutMenuBridge(controller: controller, keyWindow: keyWindow, model: resolveModel)
        self.keyWindow = keyWindow
        self.firstResponder = firstResponder
        currentModel = resolveModel
        self.bridge.dispatch = { [weak self] operation in self?.performFromMenu(operation, event: NSApp.currentEvent) }
        controller.synchronizeMenus = { [weak self] in
            self?.bridge.reconcile()
        }
    }

    func start() {
        guard monitor == nil else { return }
        bridge.start()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = []
        bridge.stop()
    }

    func handle(_ event: NSEvent, fromMenu: Bool = false) -> Bool {
        if event.type == .keyUp {
            held.remove(event.keyCode)
            return false
        }
        guard event.type == .keyDown else { return false }
        // Menu tracking can report a windowless event to the monitor before invoking its item. Let the trusted
        // menu adapter own that press; observing it here must not make its first invocation look like a hold.
        guard fromMenu || event.window != nil else { return false }
        // Track even keys received during recording, typing or a sheet. Neither menu synchronization nor a mode/
        // window change proves the physical key was released. A missed key-up costs one press, never a print job.
        let wasHeld = !held.insert(event.keyCode).inserted
        guard !controller.hotKeys.isRecording else { return false }
        // A rebuilt menu can still carry SwiftUI's stale key or enabled state until this synchronous pass.
        bridge.reconcile()
        guard let window = keyWindow(), event.window === window || (fromMenu && event.window == nil),
            window.attachedSheet == nil, NSApp.modalWindow == nil,
            let combination = Self.combination(event, allowsBareKeys: true)
        else { return false }
        let responder = firstResponder(window)
        if Self.isTextInput(responder), !combination.modifiers.contains(.command) { return false }
        let matches = Self.operations.filter { operation in
            controller.localKeys(for: operation).contains { $0 == combination }
        }
        if let input = responder as? NSTextInputClient, input.hasMarkedText() {
            // Keep recognized menu keys consumed during composition, as before surface routing existed.
            // Execute neither menu nor surface operations, and leave unmatched editing keys to the input client.
            return !matches.isEmpty
        }
        let model = currentModel()
        if let model, model.window === window, !model.blocksSurfaceShortcuts {
            if let surface = ShortcutSurfaceKeys.owner(of: responder),
                (model.mode == .view && !model.showsWeb && surface.shortcutRegion != .foldedPreview)
                    || (model.mode == .print && model.showsFold && surface.shortcutRegion == .foldedPreview),
                let operation = ShortcutSurfaceKeys.match(event, region: surface.shortcutRegion, controller: controller)
            {
                surface.performShortcut(operation, event: event)
                return true
            }
            if model.shortcutListFocused, model.binder != nil, responder != nil,
                ShortcutSurfaceKeys.owner(of: responder) == nil,
                !Self.isTextInput(responder), !(responder is NSControl) || responder is NSTableView,
                ShortcutSurfaceKeys.match(event, region: .focusedList, controller: controller) == .listRemove
            {
                if let url = model.binder?.selection { model.removeFromBinder(url) }
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
        let activeMatches = matches.filter { Self.isActive($0, model: model) }
        guard activeMatches.count == 1, let operation = activeMatches.first, !bridge.ambiguous.contains(operation)
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
        let metadata = ShortcutOperation.operation(operation)
        if metadata.applicability == .application || operation == .appCheckUpdates { return true }
        guard let model else { return false }
        let region: ShortcutRegion
        switch model.mode {
        case .view: region = model.showsWeb ? .web : .paperReading
        case .print: region = model.showsFold ? .foldedPreview : .printSheet
        case .compare: region = .comparison
        }
        return metadata.regions.contains(region)
    }

    static var operations: Set<ShortcutOperationID> {
        ShortcutMenuBridge.operations.union(ShortcutCommands.operations)
    }

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

    func perform(_ operation: ShortcutOperationID) {
        guard Self.operations.contains(operation), !controller.hotKeys.isRecording,
            NSApp.modalWindow == nil, keyWindow()?.attachedSheet == nil
        else { return }
        if let window = keyWindow(), let input = firstResponder(window) as? NSTextInputClient, input.hasMarkedText() {
            return
        }
        let model = currentModel()
        let application =
            ShortcutOperation.operation(operation).applicability == .application || operation == .appCheckUpdates
        if !application {
            guard let model, model.window === keyWindow() else { return }
        }
        guard Self.isActive(operation, model: model) else { return }
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
        case .appOpen: bridge.invokeStandard(.appOpen)
        case .appSettings: bridge.invokeStandard(.appSettings)
        case .clipboardOpen: ClipboardWindows.shared.open()
        case .appStreamingPreview: StreamingPreviewWindows.shared.open()
        case .appGettingStarted: OpenRouter.shared.openGettingStarted()
        case .appKeyGuide: KeyGuideWindow.shared.show()
        case .appCheckUpdates:
            if AppUpdater.shared.isAvailable { AppUpdater.shared.checkForUpdates() }
        case .settingSetManage:
            WelcomeController.shared.preferences?.settingsSection = .settingSets
            bridge.invokeStandard(.appSettings)
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
            if let model, model.binder != nil || model.imageBundle != nil { model.isDrawerOpen.toggle() }
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
