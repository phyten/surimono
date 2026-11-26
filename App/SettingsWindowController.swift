import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowID = NSUserInterfaceItemIdentifier("surimono.settings.v1")

    static func makeWindow(for view: SettingsView) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars]
        // SwiftUI can update the window minimum after layout. Give both layers the same screen-specific floor.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsWindowPlacement.minimumContentSize
        window.collectionBehavior.insert(.moveToActiveSpace)
        view.preferences.migrateSettingsContentSize(chrome: window.frameRect(forContentRect: .zero).size)
        window.setContentSize(SettingsWindowPlacement.defaultContentSize)
        return window
    }

    private let editor: BandArrangementEditorSession

    init(window: NSWindow, editor: BandArrangementEditorSession) {
        self.editor = editor
        super.init(window: window)
        window.identifier = Self.windowID
        window.isRestorable = false
        window.delegate = self
        editor.settingsController = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        let key = NSApp.keyWindow
        let screen = SettingsWindowPlacement.screen(
            key: key?.isOnActiveSpace == true ? key?.screen : nil,
            screens: NSScreen.screens, pointer: NSEvent.mouseLocation, frame: { $0.frame })
        if let screen,
            SettingsWindowPlacement.needsPlacement(
                isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                onActiveSpace: window.isOnActiveSpace, onTargetScreen: window.screen == screen)
        {
            placeWindow(in: screen.visibleFrame)
        }
        // Apply the same full-screen role as other auxiliaries before AppKit chooses a Space on ordering.
        AuxiliaryWindowLevel.shared.refresh(windows: [window], presenting: window)
        if window.isMiniaturized { window.deminiaturize(sender) }
        window.makeKeyAndOrderFront(sender)
    }

    func placeWindow(in visibleFrame: CGRect) {
        guard let window else { return }
        let placement = SettingsWindowPlacement(
            in: visibleFrame, savedContentSize: editor.preferences.settingsContentSize,
            chrome: window.frameRect(forContentRect: .zero).size)
        if let host = window.contentViewController as? NSHostingController<SettingsView>,
            host.rootView.windowMinimum != placement.contentMinimum
        {
            host.rootView.windowMinimum = placement.contentMinimum
            host.view.layoutSubtreeIfNeeded()
        }
        if window.contentMinSize != placement.contentMinimum { window.contentMinSize = placement.contentMinimum }
        if window.frame != placement.frame { window.setFrame(placement.frame, display: false) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        editor.preferences.settingsContentSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.isDirty else { return true }
        editor.pendingLeave = .closeWindow
        return false
    }
}

/// Undo and Redo for the arrangement editor, from the Edit menu and ⌘Z / ⇧⌘Z. It stands in the responder chain just
/// before the Settings window, so that the window's own history, which the other sections use, stays exactly as it
/// was: the router answers only while the editor shows and no text is being edited, and otherwise lets the action go
/// on to the window.
final class SettingsUndoRouter: NSResponder, NSMenuItemValidation {
    /// The editor's history while the editor shows; nil hands Undo to the window.
    var history: @MainActor () -> UndoManager? = { nil }
    var performUndo: @MainActor () -> Void = {}
    var performRedo: @MainActor () -> Void = {}
    private(set) weak var window: NSWindow?

    // Safe: only the variable's address is used, as the associated object's key; its value is never read or written.
    nonisolated(unsafe) private static var key: UInt8 = 0

    @discardableResult
    static func install(
        on window: NSWindow, history: @escaping @MainActor () -> UndoManager?, undo: @escaping @MainActor () -> Void,
        redo: @escaping @MainActor () -> Void
    ) -> SettingsUndoRouter {
        let router: SettingsUndoRouter
        if let existing = objc_getAssociatedObject(window, &key) as? SettingsUndoRouter {
            router = existing
        } else {
            router = SettingsUndoRouter()
            router.window = window
            objc_setAssociatedObject(window, &key, router, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        router.history = history
        router.performUndo = undo
        router.performRedo = redo
        router.insertIntoChain()
        return router
    }

    /// Puts the router between the last responder of the window's content and the window. SwiftUI may rebuild that
    /// chain, so the editor calls this again whenever it shows.
    func insertIntoChain() {
        guard let window, let content = window.contentView else { return }
        var responder: NSResponder = content
        for _ in 0..<32 {
            guard let next = responder.nextResponder else { break }
            if next === self { return }
            if next === window { break }
            responder = next
        }
        guard responder.nextResponder === window || responder.nextResponder == nil else { return }
        responder.nextResponder = self
        nextResponder = window
    }

    /// The editor's history, unless text has the keyboard: a text field keeps its own Undo.
    var activeHistory: UndoManager? {
        guard let history = history(), !(window?.firstResponder is NSText) else { return nil }
        return history
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(undo(_:)) || selector == #selector(redo(_:)) {
            // Actions are sent on the main thread; anywhere else the router has nothing to say.
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { activeHistory != nil }
        }
        return super.responds(to: selector)
    }

    @objc func undo(_ sender: Any?) { performUndo() }
    @objc func redo(_ sender: Any?) { performRedo() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let history = activeHistory else { return false }
        let title: String
        let enabled: Bool
        switch item.action {
        case #selector(undo(_:)): (title, enabled) = (history.undoMenuItemTitle, history.canUndo)
        case #selector(redo(_:)): (title, enabled) = (history.redoMenuItemTitle, history.canRedo)
        default: return false
        }
        if (AppKitShell.current?.menuTrackingDepth ?? 0) == 0, item.title != title { item.title = title }
        return enabled
    }
}
