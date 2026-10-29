import AppKit

/// Gives a window the print tray's size and chrome while it is in the print mode, and puts it back afterwards.
///
/// Each window remembers its own view-mode frame and title bar, so leaving the print mode restores exactly what the
/// user had, whatever the view mode looks like.
enum PrintModeWindow {
    static let traySize = NSSize(width: 1000, height: 760)
    static let animationDuration: TimeInterval = 0.3

    private final class SavedChrome {
        let frame: NSRect
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
        let hadFullSizeContentView: Bool

        init(_ window: NSWindow) {
            frame = window.frame
            titleVisibility = window.titleVisibility
            titlebarAppearsTransparent = window.titlebarAppearsTransparent
            titlebarSeparatorStyle = window.titlebarSeparatorStyle
            hadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
        }
    }

    private static let saved = NSMapTable<NSWindow, SavedChrome>.weakToStrongObjects()
    private static let leaving = NSHashTable<NSWindow>.weakObjects()

    static func enter(_ window: NSWindow) {
        guard saved.object(forKey: window) == nil else { return }
        let chrome = SavedChrome(window)
        saved.setObject(chrome, forKey: window)
        // The tray draws its own top bar under the title bar. The window keeps its toolbar (SwiftUI observes and owns
        // it); the print mode only hides the toolbar's items, so the traffic lights stay centered in the bar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        setFrame(trayFrame(around: chrome.frame, visibleFrame: screen.visibleFrame), of: window)
    }

    /// Shrinks the window back first and restores its title bar when it has its old frame, so `completion` (which
    /// brings back the view mode) lays the pages out once, at their final size.
    static func exit(_ window: NSWindow, completion: @escaping () -> Void) {
        // A second request while the window shrinks back changes nothing; the first one finishes the job.
        guard !leaving.contains(window) else { return }
        guard let chrome = saved.object(forKey: window) else {
            completion()
            return
        }
        saved.removeObject(forKey: window)
        leaving.add(window)
        let restore = {
            leaving.remove(window)
            window.titleVisibility = chrome.titleVisibility
            window.titlebarAppearsTransparent = chrome.titlebarAppearsTransparent
            window.titlebarSeparatorStyle = chrome.titlebarSeparatorStyle
            if !chrome.hadFullSizeContentView {
                // AppKit keeps the content size when the content stops running under the title bar, which would
                // grow the window by the title bar's height.
                window.styleMask.remove(.fullSizeContentView)
                window.setFrame(chrome.frame, display: true)
            }
            completion()
        }
        guard !window.styleMask.contains(.fullScreen) else {
            restore()
            return
        }
        setFrame(chrome.frame, of: window, completion: restore)
    }

    /// The tray frame: about `size`, centered on the view-mode window and kept inside the screen's visible frame.
    static func trayFrame(around frame: NSRect, visibleFrame: NSRect, size: NSSize = traySize) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let x = min(max(frame.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.midY - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    private static func setFrame(_ frame: NSRect, of window: NSWindow, completion: (() -> Void)? = nil) {
        guard window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            completion?()
            return
        }
        // The completion handler is @Sendable, so it carries only an identifier to the main-actor state.
        let id = UUID()
        if let completion { pendingCompletions[id] = completion }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { pendingCompletions.removeValue(forKey: id)?() }
        }
    }

    private static var pendingCompletions: [UUID: () -> Void] = [:]
}
