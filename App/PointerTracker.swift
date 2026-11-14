import AppKit
import SwiftUI

/// Follows the pointer by where it is on the screen and reports it in the window's content, top-left based.
///
/// The place on the screen stays right while the window grows or shrinks around a still pointer, and does not stop
/// where the title bar lies over the content, which is where the top band shows: with SwiftUI's hover the band was
/// reported to come and go under a pointer that did not move.
///
/// Nothing polls: a tracking area over the whole content reports the pointer's moves, and the window's own changes
/// (moving, resizing, being covered or shown) ask again. It is active always, so a window floating on top is followed
/// while another app is active too. Bands that always show need none of it.
struct PointerTracker: NSViewRepresentable {
    var isActive = true
    let onChange: (_ point: CGPoint?, _ contentHeight: CGFloat) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onChange = onChange
        view.isActive = isActive
    }

    final class TrackerView: NSView {
        #if DEBUG
            /// A pointer place on the screen for development snapshots, in place of the reader's, for every window.
            static var debugMouseLocation: NSPoint? {
                didSet { for view in live.allObjects { view.debugMouseLocation = debugMouseLocation } }
            }
            private static let live = NSHashTable<TrackerView>.weakObjects()
            /// The same for this window alone, as tests running side by side need.
            var debugMouseLocation: NSPoint? {
                didSet { evaluate() }
            }
        #endif

        var onChange: ((CGPoint?, CGFloat) -> Void)?
        var isActive = true {
            didSet {
                guard isActive != oldValue else { return }
                updateTrackingAreas()
                evaluate()
            }
        }
        private var area: NSTrackingArea?
        private var reported: Report?

        private struct Report: Equatable {
            var point: CGPoint?
            var contentHeight: CGFloat
        }

        /// Whether the view follows the pointer now: on a window, for bands that show on pointing.
        var isMonitoring: Bool { area != nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            area = nil
            guard isActive, window != nil else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self)
            addTrackingArea(area)
            self.area = area
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reported = nil
            updateTrackingAreas()
            #if DEBUG
                if window != nil { Self.live.add(self) } else { Self.live.remove(self) }
            #endif
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [
                NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didEndLiveResizeNotification,
            ] {
                center.addObserver(self, selector: #selector(windowDidChange), name: name, object: window)
            }
            evaluate()
        }

        override func mouseMoved(with event: NSEvent) { evaluate() }
        override func mouseEntered(with event: NSEvent) { evaluate() }
        override func mouseExited(with event: NSEvent) { evaluate() }
        override func mouseDragged(with event: NSEvent) { evaluate() }

        /// Asked after the change has been handled: a window that grew for the bands has their room in the pointer's
        /// zones only once the update that grew it is over.
        @objc private func windowDidChange(_ note: Notification) {
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        func evaluate() {
            guard isActive, let window else { return }
            var mouse = NSEvent.mouseLocation
            var simulated = false
            #if DEBUG
                if let location = debugMouseLocation {
                    mouse = location
                    simulated = true
                }
            #endif
            // A window being resized by the reader keeps its bands as they are until the resize ends; a covered or
            // hidden window has nothing to show.
            guard !window.inLiveResize, simulated || (window.isVisible && window.occlusionState.contains(.visible))
            else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let point = Self.contentPoint(
                of: mouse, in: content,
                isFront: {
                    simulated || NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) == window.windowNumber
                })
            let report = Report(point: point, contentHeight: content.height)
            guard report != reported else { return }
            reported = report
            onChange?(point, content.height)
        }

        /// The pointer in the content, measured from its top-left corner; nil when it is outside or over another
        /// window.
        static func contentPoint(of mouse: NSPoint, in content: NSRect, isFront: (NSPoint) -> Bool) -> CGPoint? {
            guard content.contains(mouse), isFront(mouse) else { return nil }
            return CGPoint(x: mouse.x - content.minX, y: content.maxY - mouse.y)
        }
    }
}
