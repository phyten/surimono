import AppKit
import OSLog
import SwiftUI

/// Stands in front of the Settings window's own delegate, which SwiftUI keeps, and passes on everything it does not
/// answer itself. It only asks before the window closes over unsaved work. Should SwiftUI give the window another
/// delegate, the guard notices and stands in front of that one, after SwiftUI's update; a window that keeps replacing
/// it is tried again later, and until then unsaved work keeps the close button off.
final class SettingsWindowGuard: NSObject, NSWindowDelegate {
    /// False to keep the window open; the guard's owner then asks the reader and closes the window itself.
    var shouldClose: @MainActor () -> Bool = { true }
    /// Whether there is work the window must not close over, asked without side effects.
    var needsProtection: @MainActor () -> Bool = { false }
    // Safe: changed only on the main thread, where AppKit also asks the delegate what it answers.
    nonisolated(unsafe) private(set) weak var original: NSWindowDelegate?
    private(set) weak var window: NSWindow?
    private var delegateObservation: NSKeyValueObservation?
    /// Reinstalls within the last second: a window that keeps taking its delegate back is tried again later.
    private var recentReinstalls: [Date] = []
    private var retry: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(1)
    /// The guard turned the close button off and turns it back on.
    private var lockedCloseButton = false
    private static let logger = Logger(subsystem: "app.surimono.Surimono", category: "Settings")

    // Safe: only the variable's address is used, as the associated object's key; its value is never read or written.
    nonisolated(unsafe) private static var key: UInt8 = 0

    /// One guard per window; installing again updates the closure. The window keeps its delegate weakly, so the guard
    /// is tied to the window for as long as the window lives. A new window gets its own guard.
    @discardableResult
    static func install(
        on window: NSWindow, shouldClose: @escaping @MainActor () -> Bool,
        needsProtection: @escaping @MainActor () -> Bool = { false }
    ) -> SettingsWindowGuard {
        let windowGuard: SettingsWindowGuard
        if let existing = objc_getAssociatedObject(window, &key) as? SettingsWindowGuard {
            windowGuard = existing
        } else {
            windowGuard = SettingsWindowGuard()
            windowGuard.window = window
            objc_setAssociatedObject(window, &key, windowGuard, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            windowGuard.delegateObservation = window.observe(\.delegate) { [weak windowGuard] _, _ in
                // Not from inside the update that set it: changing a window SwiftUI is updating can crash it.
                Task { @MainActor in windowGuard?.reinstallIfNeeded() }
            }
        }
        windowGuard.shouldClose = shouldClose
        windowGuard.needsProtection = needsProtection
        windowGuard.reinstallIfNeeded()
        return windowGuard
    }

    /// Stands in front of whatever delegate the window has now, unless it is already this guard.
    func reinstallIfNeeded() {
        defer { refreshProtection() }
        guard let window, window.delegate !== self else { return }
        let now = Date()
        recentReinstalls = recentReinstalls.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard recentReinstalls.count <= 3 else {
            scheduleRetry()
            return
        }
        original = window.delegate
        window.delegate = self
        retryDelay = .seconds(1)
    }

    /// One retry at a time, waiting longer each time the window took its delegate back again (up to 8 seconds).
    private func scheduleRetry() {
        guard retry == nil else { return }
        Self.logger.error("The Settings window keeps replacing its delegate; the close guard tries again later")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(8))
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            retry = nil
            reinstallIfNeeded()
        }
    }

    /// While the guard is not the delegate, unsaved work keeps the window open without it: the close button is off,
    /// and both the button and ⌘W (`performClose`) need it. It comes back on once the guard asks again or nothing is
    /// unsaved.
    func refreshProtection() {
        guard let window, let button = window.standardWindowButton(.closeButton) else { return }
        if window.delegate !== self, needsProtection() {
            button.isEnabled = false
            lockedCloseButton = true
        } else if lockedCloseButton {
            button.isEnabled = true
            lockedCloseButton = false
        }
    }

    /// Closes the window without asking again, after the reader answered.
    func closeWithoutAsking() {
        let ask = shouldClose
        shouldClose = { true }
        window?.performClose(nil)
        shouldClose = ask
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
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
        switch item.action {
        case #selector(undo(_:)):
            item.title = history.undoMenuItemTitle
            return history.canUndo
        case #selector(redo(_:)):
            item.title = history.redoMenuItemTitle
            return history.canRedo
        default:
            return false
        }
    }
}
