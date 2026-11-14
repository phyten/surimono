import AppKit
import SwiftUI

/// Follows the pointer by where it is on the screen and reports it in the window's content, top-left based.
///
/// SwiftUI's hover stops where the title bar lies over the content, which is where the top band shows: the band came
/// and went under a pointer that did not move, and the traffic lights with it. Reading the pointer's place also keeps
/// the report right while the window grows or shrinks around a still pointer.
struct PointerTracker: NSViewRepresentable {
    let onChange: (_ point: CGPoint?, _ contentHeight: CGFloat) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) { view.onChange = onChange }

    final class TrackerView: NSView {
        static let interval: TimeInterval = 0.05
        #if DEBUG
            /// A pointer place on the screen for development snapshots, in place of the reader's.
            static var debugMouseLocation: NSPoint?
        #endif
        var onChange: ((CGPoint?, CGFloat) -> Void)?
        private var timer: Timer?
        private var reported: CGPoint??

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            reported = nil
            guard window != nil else { return }
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func poll() {
            var mouse = NSEvent.mouseLocation
            var simulated = false
            #if DEBUG
                if let location = Self.debugMouseLocation {
                    mouse = location
                    simulated = true
                }
            #endif
            // A window being resized by the reader keeps its bands as they are until the resize ends.
            guard let window, window.isVisible, simulated || window.occlusionState.contains(.visible),
                !window.inLiveResize
            else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let point = Self.contentPoint(
                of: mouse, in: content,
                isFront: {
                    simulated || NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) == window.windowNumber
                })
            guard reported != .some(point) else { return }
            reported = .some(point)
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
