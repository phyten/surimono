import AppKit
import SwiftUI

/// Stands in front of the Settings window's own delegate, which SwiftUI keeps, and passes on everything it does not
/// answer itself. It asks before the window closes over unsaved work, and while the arrangement editor shows it hands
/// the window the editor's history, so that Edit > Undo undoes the editor's steps rather than another section's.
final class SettingsWindowGuard: NSObject, NSWindowDelegate {
    /// False to keep the window open; the guard's owner then asks the reader and closes the window itself.
    var shouldClose: () -> Bool = { true }
    /// The history to use instead of the window's own, while there is one.
    var undoManager: () -> UndoManager? = { nil }
    // Safe: set once in `install`, before the guard becomes the delegate, and never changed; AppKit may ask the
    // delegate what it answers from wherever it likes.
    nonisolated(unsafe) private(set) weak var original: NSWindowDelegate?
    private weak var window: NSWindow?

    // Safe: only the variable's address is used, as the associated object's key; its value is never read or written.
    nonisolated(unsafe) private static var key: UInt8 = 0

    /// One guard per window; installing again updates the closures. The window keeps its delegate weakly, so the
    /// guard is tied to the window for as long as the window lives; a Settings window that closes and comes back is
    /// still guarded.
    @discardableResult
    static func install(
        on window: NSWindow, shouldClose: @escaping () -> Bool, undoManager: @escaping () -> UndoManager?
    ) -> SettingsWindowGuard {
        let windowGuard: SettingsWindowGuard
        if let existing = objc_getAssociatedObject(window, &key) as? SettingsWindowGuard, window.delegate === existing {
            windowGuard = existing
        } else {
            windowGuard = SettingsWindowGuard()
            windowGuard.original = window.delegate
            windowGuard.window = window
            objc_setAssociatedObject(window, &key, windowGuard, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = windowGuard
        }
        windowGuard.shouldClose = shouldClose
        windowGuard.undoManager = undoManager
        return windowGuard
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

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undoManager() ?? original?.windowWillReturnUndoManager?(window)
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}
