import AppKit

// Stage entry needs more room only when its controls would not fit; fitting paper on return belongs to the model.
enum PrintModeWindow {
    static let traySize = NSSize(width: 760, height: 560)

    private final class SavedChrome {
        let frame: NSRect
        var didEnlarge = false
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

    static let compareSize = NSSize(width: 900, height: 620)

    // Switching stages must keep the frame from before either stage was opened.
    static func enter(_ window: NSWindow, size: NSSize = traySize) {
        let chrome: SavedChrome
        if let existing = saved.object(forKey: window) {
            chrome = existing
        } else {
            chrome = SavedChrome(window)
            saved.setObject(chrome, forKey: window)
            // The tray draws its own top bar under the title bar. The window keeps its toolbar (SwiftUI observes and
            // owns it); the print mode only hides the toolbar's items, so the traffic lights stay centered in the bar.
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        }
        ViewerWindow.unlockAspectRatio(of: window)
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        let frame = trayFrame(around: window.frame, visibleFrame: screen.visibleFrame, size: size)
        guard frame != window.frame else { return }
        chrome.didEnlarge = true
        ViewerWindow.setStageFrame(frame, of: window)
    }

    // Undo only the automatic enlargement here. The completion fits the paper width while keeping this height.
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
            if window.titleVisibility != chrome.titleVisibility { window.titleVisibility = chrome.titleVisibility }
            if window.titlebarAppearsTransparent != chrome.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = chrome.titlebarAppearsTransparent
            }
            if window.titlebarSeparatorStyle != chrome.titlebarSeparatorStyle {
                window.titlebarSeparatorStyle = chrome.titlebarSeparatorStyle
            }
            if !chrome.hadFullSizeContentView {
                // AppKit keeps the content size when the content stops running under the title bar, which would
                // grow the window by the title bar's height.
                let frame = window.frame
                window.styleMask.remove(.fullSizeContentView)
                ViewerWindow.setFrame(frame, of: window, animate: false)
            }
            completion()
        }
        guard chrome.didEnlarge, !window.styleMask.contains(.fullScreen) else {
            restore()
            return
        }
        ViewerWindow.setStageFrame(chrome.frame, of: window, completion: restore)
    }

    // Grow only missing dimensions, preserving the other dimension even on a smaller screen.
    static func trayFrame(around frame: NSRect, visibleFrame: NSRect, size: NSSize = traySize) -> NSRect {
        let width = max(frame.width, min(size.width, visibleFrame.width))
        let height = max(frame.height, min(size.height, visibleFrame.height))
        guard width != frame.width || height != frame.height else { return frame }
        let x =
            width == frame.width
            ? frame.minX
            : min(max(frame.midX - width / 2, visibleFrame.minX), visibleFrame.maxX - width).rounded()
        let y =
            height == frame.height
            ? frame.minY
            : min(max(frame.midY - height / 2, visibleFrame.minY), visibleFrame.maxY - height).rounded()
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
