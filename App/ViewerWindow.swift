import AppKit

/// Window handling for the borderless view mode: the paper fills the window, the title bar is hidden, and the
/// traffic lights appear together with the overlay menu.
enum ViewerWindow {
    /// Shorter than the top margin of an A4 page in the standard style, so the band rarely covers text.
    static let bandHeight: CGFloat = 38
    private static let minimumPaperHeight: CGFloat = 280
    /// Animated frame changes post live-resize notifications; these windows are being resized by the app itself.
    private static let resizingWindows = NSHashTable<NSWindow>.weakObjects()

    static func isResizingProgrammatically(_ window: NSWindow) -> Bool { resizingWindows.contains(window) }

    /// Treats live-resize notifications of the next moments as the app's own, for frame changes made elsewhere.
    static func markResizing(_ window: NSWindow, for duration: TimeInterval) {
        resizingWindows.add(window)
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(duration))
            if let window { resizingWindows.remove(window) }
        }
    }

    private static func setFrame(_ frame: NSRect, of window: NSWindow, animate: Bool) {
        guard frame.integral != window.frame.integral else { return }
        resizingWindows.add(window)
        guard animate else {
            window.setFrame(frame, display: true, animate: false)
            resizingWindows.remove(window)
            return
        }
        // The animation reports the end of its live resize after this call returns.
        let duration = window.animationResizeTime(frame)
        window.setFrame(frame, display: true, animate: true)
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(duration + 0.25))
            if let window { resizingWindows.remove(window) }
        }
    }

    static func configure(_ window: NSWindow) {
        // Setting a property notifies its KVO observers even when the value stays the same, and SwiftUI observes some
        // of these; so only change what differs.
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
    }

    static func setTrafficLightsVisible(_ visible: Bool, in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        // Hidden buttons must not stay clickable, so hide them once they have faded out.
        if visible {
            for button in buttons { button.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            for button in buttons { button.animator().alphaValue = visible ? 1 : 0 }
        } completionHandler: {
            guard !visible else { return }
            for button in buttons where button.alphaValue == 0 { button.isHidden = true }
        }
    }

    static func setAlwaysOnTop(_ onTop: Bool, in window: NSWindow) {
        window.level = onTop ? .floating : .normal
    }

    /// The paper size for a newly opened document: as tall as comfortably fits the screen, at the unit's aspect.
    static func initialPaperSize(unit: CGSize, on screen: NSScreen?) -> CGSize {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        guard unit.width > 0, unit.height > 0 else { return CGSize(width: 600, height: 800) }
        var height = min(visible.height * 0.86, 1000)
        var width = height * unit.width / unit.height
        let maximumWidth = visible.width * 0.9
        if width > maximumWidth {
            width = maximumWidth
            height = width * unit.height / unit.width
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The current paper height of the window, excluding the band.
    static func paperHeight(of window: NSWindow, band: CGFloat) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height - band
    }

    /// Resizes the window so that the paper area is `paper`, keeping the top-left corner in place and the window on
    /// screen, and locks resizing to the paper's aspect ratio.
    static func setPaperSize(_ paper: CGSize, band: CGFloat, of window: NSWindow, animate: Bool) {
        guard paper.width > 0, paper.height > 0 else { return }
        let content = NSRect(x: 0, y: 0, width: paper.width, height: paper.height + band)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        setFrame(constrained(frame, on: window.screen), of: window, animate: animate)
        lockAspectRatio(of: window, unit: paper, band: band)
    }

    /// Adds or removes the band above the paper without moving the paper: the window grows or shrinks at the top.
    static func setBand(_ band: CGFloat, previous: CGFloat, of window: NSWindow, unit: CGSize) {
        var frame = window.frame
        frame.size.height += band - previous
        setFrame(constrained(frame, on: window.screen), of: window, animate: true)
        lockAspectRatio(of: window, unit: unit, band: band)
    }

    static func lockAspectRatio(of window: NSWindow, unit: CGSize, band: CGFloat) {
        guard unit.width > 0, unit.height > 0 else { return }
        let paperHeight = max(Self.paperHeight(of: window, band: band), 1)
        let paperWidth = paperHeight * unit.width / unit.height
        // An aspect ratio cannot express "paper plus a fixed band", so the band is included at the current size.
        window.contentAspectRatio = NSSize(width: paperWidth, height: paperHeight + band)
        window.contentMinSize = NSSize(
            width: minimumPaperHeight * unit.width / unit.height, height: minimumPaperHeight + band)
    }

    static func unlockAspectRatio(of window: NSWindow) {
        // Per AppKit, resize increments of 1×1 remove an aspect ratio constraint.
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentMinSize = NSSize(width: 480, height: 360)
    }

    private static func constrained(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
        var frame = frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        return frame
    }
}
