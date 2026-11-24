import AppKit
import SurimonoCore
import SwiftUI

/// The room the bands take above and below the paper.
struct BandRoom: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    var total: CGFloat { top + bottom }

    /// The room of every band of the arrangement. The top band is as tall as `top`: the title band's height in a
    /// window, the plain band's in full screen.
    static func full(for arrangement: MenuArrangement, top: CGFloat = ViewerWindow.titleBandHeight) -> BandRoom {
        BandRoom(top: top, bottom: arrangement == .split ? ViewerWindow.bandHeight : 0)
    }
}

/// Window handling for the borderless view mode: the title bar is hidden, room for the bands is kept beside the paper
/// while they show, and the traffic lights appear together with the bands.
enum ViewerWindow {
    /// The room of the band under the paper, and of the top band where the window shows no traffic lights (full
    /// screen).
    static let bandHeight: CGFloat = 38
    /// Below this the band's controls would have too little room above and below them.
    static let minimumTitleBandHeight: CGFloat = 30
    /// The room of the top band beside the paper in a window: twice the traffic lights' centre, so that its parts are
    /// in the middle of the band and on the lights' line at once. AppKit centres the lights in a title bar whose height
    /// depends on the macOS version (32pt on macOS 26, 28pt before), and the window is sized before any window of the
    /// document could be measured; so it is read once from a window like the view mode's that is never shown.
    static let titleBandHeight = titleBandHeight(lightsCenter: probedLightsCenter())
    /// The band's controls take the small size where the title band is too low for the regular one with room to spare.
    static var bandControlSize: ControlSize { titleBandHeight < 32 ? .small : .regular }

    static func titleBandHeight(lightsCenter: CGFloat?) -> CGFloat {
        guard let lightsCenter else { return bandHeight }
        return max(minimumTitleBandHeight, (2 * lightsCenter).rounded())
    }

    private static func probedLightsCenter() -> CGFloat? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        configure(window)
        defer { window.close() }
        return TrafficLights(window: window)?.centerY
    }
    private static let minimumPaperHeight: CGFloat = 280
    private static let resizeTokens = NSMapTable<NSWindow, NSMutableSet>.weakToStrongObjects()

    static func isResizingProgrammatically(_ window: NSWindow) -> Bool {
        (resizeTokens.object(forKey: window)?.count ?? 0) > 0
    }

    // A synchronous stage change can finish inside the grace period of an animated resize in the same window.
    private static func beginResize(of window: NSWindow) -> @MainActor () -> Void {
        let tokens = resizeTokens.object(forKey: window) ?? NSMutableSet()
        resizeTokens.setObject(tokens, forKey: window)
        let token = UUID()
        tokens.add(token)
        return { tokens.remove(token) }
    }

    private static func after(_ duration: TimeInterval, perform: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            perform()
        }
    }

    /// Treats live-resize notifications of the next moments as the app's own, for frame changes made elsewhere.
    static func markResizing(
        _ window: NSWindow, for duration: TimeInterval,
        schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = after
    ) {
        schedule(duration, beginResize(of: window))
    }

    static func setFrame(_ frame: NSRect, of window: NSWindow, animate: Bool) {
        guard frame.integral != window.frame.integral else { return }
        let finish = beginResize(of: window)
        guard animate else {
            window.setFrame(frame, display: true, animate: false)
            finish()
            return
        }
        // The animation reports the end of its live resize after this call returns.
        let duration = window.animationResizeTime(frame)
        window.setFrame(frame, display: true, animate: true)
        after(duration + 0.25, perform: finish)
    }

    /// A stage takes its frame in one step, in the same update as the mode that comes with it. An animated frame laid
    /// the tray or the paper out again on every step (a dozen to twenty times per switch), the press bar changed from
    /// stacked to side by side halfway through, and leaving the tray only showed the paper after the animation.
    ///
    /// `display: false` leaves the drawing to the window's next update, for a frame the completion may still change.
    static func setStageFrame(
        _ frame: NSRect, of window: NSWindow, display: Bool = true, completion: (() -> Void)? = nil
    ) {
        if frame != window.frame {
            let finish = beginResize(of: window)
            window.setFrame(frame, display: display)
            finish()
        }
        completion?()
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

    private static let movedToActiveSpace = NSHashTable<NSWindow>.weakObjects()

    static func setShowsOnAllSpaces(_ enabled: Bool, in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        var behavior = window.collectionBehavior
        behavior.subtract([.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenNone, .canJoinAllSpaces])
        if enabled {
            if behavior.remove(.moveToActiveSpace) != nil { movedToActiveSpace.add(window) }
            behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        } else {
            // Free resizing on the print tray needs an explicit primary role to keep Enter Full Screen available.
            behavior.insert(.fullScreenPrimary)
            if movedToActiveSpace.contains(window) {
                behavior.insert(.moveToActiveSpace)
                movedToActiveSpace.remove(window)
            }
        }
        if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        AuxiliaryWindowLevel.shared.refresh(windows: NSApp.windows)
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
        AuxiliaryWindowLevel.shared.registerDocument(window)
        let level: NSWindow.Level = onTop ? .floating : .normal
        if window.level != level { window.level = level }
        AuxiliaryWindowLevel.shared.refresh(windows: NSApp.windows)
    }

    /// The paper size for a newly opened document: as tall as comfortably fits the screen, at the unit's aspect.
    static func initialPaperSize(unit: CGSize, on screen: NSScreen?, side: CGFloat = 0) -> CGSize {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        guard unit.width > 0, unit.height > 0 else { return CGSize(width: 600, height: 800) }
        var height = min(visible.height * 0.86, 1000)
        var width = height * unit.width / unit.height
        let maximumWidth = max(1, visible.width * 0.9 - side)
        if width > maximumWidth {
            width = maximumWidth
            height = width * unit.height / unit.width
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// The paper size of the unit's shape at `height`, made smaller to fit the screen when it is too wide.
    static func paperSize(
        unit: CGSize, height: CGFloat, on screen: NSScreen?, widthShare: CGFloat = 0.9, side: CGFloat = 0
    ) -> CGSize {
        guard unit.width > 0, unit.height > 0, height > 0 else {
            return initialPaperSize(unit: unit, on: screen, side: side)
        }
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        var size = CGSize(width: height * unit.width / unit.height, height: height)
        let maximumWidth = max(1, visible.width * widthShare - side)
        if size.width > maximumWidth {
            size = CGSize(width: maximumWidth, height: maximumWidth * unit.height / unit.width)
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// The current paper height of the window, excluding the room of the bands.
    static func paperHeight(of window: NSWindow, band: CGFloat) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height - band
    }

    /// Resizes the window so that the paper area is `paper`, keeping the top-left (or top-right) corner in place and
    /// the window on screen, and locks resizing to the paper's aspect ratio. `topGrowth` raises the top edge instead,
    /// for room that comes or goes above the paper.
    static func setPaperSize(
        _ paper: CGSize, band: CGFloat, of window: NSWindow, animate: Bool, keepsRightEdge: Bool = false,
        side: CGFloat = 0, topGrowth: CGFloat = 0
    ) {
        guard paper.width > 0, paper.height > 0 else { return }
        // Every size the app gives the view mode leaves the bands room for what never leaves them; the paper keeps its
        // shape at that width.
        var paper = paper
        let minimum = bandMinimumWidth(of: window)
        if paper.width + side < minimum {
            let width = (minimum - side).rounded(.up)
            paper = CGSize(width: width, height: (paper.height * width / paper.width).rounded())
        }
        let content = NSRect(x: 0, y: 0, width: paper.width + side, height: paper.height + band)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = keepsRightEdge ? window.frame.maxX - frame.width : window.frame.minX
        frame.origin.y = window.frame.maxY + topGrowth - frame.height
        setFrame(constrained(frame, on: window.screen), of: window, animate: animate)
        lockAspectRatio(of: window, unit: paper, band: band, side: side)
    }

    static func lockAspectRatio(of window: NSWindow, unit: CGSize, band: CGFloat, side: CGFloat = 0) {
        guard unit.width > 0, unit.height > 0 else { return }
        let paperHeight = max(Self.paperHeight(of: window, band: band), 1)
        let paperWidth = paperHeight * unit.width / unit.height
        // An aspect ratio cannot express "paper plus a fixed band", so the band is included at the current size.
        window.contentAspectRatio = NSSize(width: paperWidth + side, height: paperHeight + band)
        aspectLocks.setObject(AspectLock(unit: unit, band: band, side: side), forKey: window)
        window.contentMinSize = minimumContentSize(
            unit: unit, band: band, side: side, bandMinimum: bandMinimumWidth(of: window))
    }

    static func unlockAspectRatio(of window: NSWindow) {
        // Per AppKit, resize increments of 1×1 remove an aspect ratio constraint.
        window.resizeIncrements = NSSize(width: 1, height: 1)
        aspectLocks.removeObject(forKey: window)
        window.contentMinSize = NSSize(width: max(480, bandMinimumWidth(of: window)), height: 360)
    }

    /// The smallest content of a window locked to the paper's shape: the paper no lower than `minimumPaperHeight`, and
    /// no narrower than the bands' fixed parts (`bandMinimum`), with the height that keeps the shape at that width.
    static func minimumContentSize(unit: CGSize, band: CGFloat, side: CGFloat, bandMinimum: CGFloat) -> NSSize {
        let paperWidth = max(minimumPaperHeight * unit.width / unit.height, bandMinimum - side)
        return NSSize(width: paperWidth + side, height: paperWidth * unit.height / unit.width + band)
    }

    /// The narrowest content the window's bands can lay out (`BandPlans.minimumWidth`), which every later minimum size
    /// of the window respects too.
    static func setBandMinimumWidth(_ width: CGFloat, of window: NSWindow) {
        guard bandMinimumWidth(of: window) != width else { return }
        bandMinimumWidths.setObject(NSNumber(value: Double(width)), forKey: window)
        if let lock = aspectLocks.object(forKey: window) {
            window.contentMinSize = minimumContentSize(
                unit: lock.unit, band: lock.band, side: lock.side, bandMinimum: width)
        } else if window.contentMinSize.width < width {
            window.contentMinSize.width = width
        }
    }

    static func bandMinimumWidth(of window: NSWindow) -> CGFloat {
        bandMinimumWidths.object(forKey: window).map { CGFloat($0.doubleValue) } ?? 0
    }

    private final class AspectLock {
        let unit: CGSize
        let band: CGFloat
        let side: CGFloat

        init(unit: CGSize, band: CGFloat, side: CGFloat) {
            self.unit = unit
            self.band = band
            self.side = side
        }
    }

    private static let bandMinimumWidths = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    /// The last shape each window was locked to, so that a new band minimum keeps it.
    private static let aspectLocks = NSMapTable<NSWindow, AspectLock>.weakToStrongObjects()

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
