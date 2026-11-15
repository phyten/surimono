import AppKit
import SurimonoCore

@MainActor
final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher(controller: .shared)
    let controller: ShortcutController
    let bridge: ShortcutMenuBridge
    private let keyWindow: () -> NSWindow?
    private let currentModel: () -> DocumentViewModel?
    private var monitor: Any?
    private var held: Set<UInt16> = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    var executeOverride: ((ShortcutOperationID) -> Void)?

    init(
        controller: ShortcutController, bridge: ShortcutMenuBridge? = nil,
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        model: (() -> DocumentViewModel?)? = nil
    ) {
        let resolveModel = model ?? { DocumentWindows.shared.model(for: keyWindow()) }
        self.controller = controller
        self.bridge = bridge ?? ShortcutMenuBridge(controller: controller, keyWindow: keyWindow, model: resolveModel)
        self.keyWindow = keyWindow
        currentModel = resolveModel
        self.bridge.dispatch = { [weak self] operation in self?.perform(operation) }
        controller.synchronizeMenus = { [weak self] in
            self?.held.removeAll()
            self?.bridge.reconcile()
        }
    }

    func start() {
        guard monitor == nil else { return }
        bridge.start()
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            lifecycleObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.held.removeAll() }
                })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        held = []
        bridge.stop()
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            held.remove(event.keyCode)
            return false
        }
        guard event.type == .keyDown, !controller.hotKeys.isRecording else { return false }
        // A rebuilt menu can still carry SwiftUI's stale key or enabled state until this synchronous pass.
        bridge.reconcile()
        guard let window = keyWindow(), event.window === window,
            window.attachedSheet == nil, NSApp.modalWindow == nil,
            let combination = Self.combination(event)
        else { return false }
        if Self.isTextInput(window.firstResponder), !combination.modifiers.contains(.command) { return false }
        let matches = ShortcutMenuBridge.operations.filter { operation in
            controller.localKeys(for: operation).contains { $0 == combination }
        }
        guard !matches.isEmpty else { return false }
        guard matches.count == 1, let operation = matches.first, !bridge.ambiguous.contains(operation) else {
            return true
        }
        let safety = ShortcutOperation.operation(operation).safety
        if safety == .changesMode || safety == .printing || safety == .export {
            if event.isARepeat || held.contains(event.keyCode) { return true }
            held.insert(event.keyCode)
        }
        perform(operation)
        return true
    }

    static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextInputClient
    }

    static func combination(_ event: NSEvent) -> ShortcutCombination? {
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard !modifiers.intersection([.command, .control]).isEmpty else { return nil }
        if event.modifierFlags.contains(.function) {
            guard let named = ShortcutKeyboardLayout.special[event.keyCode],
                ShortcutMenuKey.character(.named(named)) == text
            else { return nil }
        }
        let named = ShortcutMenuKey.named(text)
        return try? ShortcutCombination(key: named.map(ShortcutKey.named) ?? .character(text), modifiers: modifiers)
            .normalized()
    }

    func perform(_ operation: ShortcutOperationID) {
        guard ShortcutMenuBridge.operations.contains(operation), !controller.hotKeys.isRecording,
            NSApp.modalWindow == nil, keyWindow()?.attachedSheet == nil
        else { return }
        if let input = keyWindow()?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return }
        let model = currentModel()
        let application =
            ShortcutOperation.operation(operation).applicability == .application || operation == .appCheckUpdates
        if !application {
            guard let model, model.window === keyWindow() else { return }
        }
        if let executeOverride {
            executeOverride(operation)
            return
        }
        switch operation {
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
        case .documentReload: model?.reload()
        case .documentSaveAsFile: model?.saveAsFile()
        case .documentAdd: model?.chooseDocumentsToAdd()
        case .documentOpenBinder: model?.openIncludesAsBinder()
        case .documentResetSettings: model?.resetDocumentSettings()
        case .viewHtmlPresentation: model?.toggleHTMLPresentation()
        case .viewIgnoreSlides:
            if let model { model.setIgnoresSlides(!model.ignoresSlides) }
        case .textDecrease: model?.decreaseTextSize()
        case .textReset: model?.resetTextSize()
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
