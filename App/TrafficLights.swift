import AppKit
import SwiftUI

/// Where AppKit puts a window's traffic lights, measured in the window's content from its top-left corner.
///
/// The bars at the top of a window (the view mode's band, the print screen's and the compare screen's top bars) line
/// up with the buttons instead of moving them: AppKit lays the buttons out again on every resize, full-screen change
/// and toolbar change, and the place it picks depends on the title bar and the macOS version.
struct TrafficLights: Equatable {
    /// The buttons' vertical centre, from the top of the content.
    var centerY: CGFloat
    /// The trailing edge of the zoom button, from the leading edge of the content.
    var trailingX: CGFloat

    /// The room between the zoom button and the first part of a top bar: wide enough not to read as a fourth button,
    /// close enough to belong to the same bar.
    static let titleGap: CGFloat = 14

    /// Nil when the buttons are not in the window's own title bar, as in full screen, where the system shows them
    /// elsewhere.
    @MainActor init?(window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton), close.window === window,
            let zoom = window.standardWindowButton(.zoomButton), zoom.window === window,
            let content = window.contentView
        else { return nil }
        let closeFrame = content.convert(close.bounds, from: close)
        let zoomFrame = content.convert(zoom.bounds, from: zoom)
        centerY = content.isFlipped ? closeFrame.midY : content.bounds.height - closeFrame.midY
        trailingX = zoomFrame.maxX
    }

    init(centerY: CGFloat, trailingX: CGFloat) {
        self.centerY = centerY
        self.trailingX = trailingX
    }

    /// Where the first part of a top bar starts.
    var titleLeading: CGFloat { trailingX + Self.titleGap }

    /// How far a bar of `height` at the top of the window moves all of its parts so that they share one centre line
    /// with the buttons. Without buttons in the window the parts stay in the bar's middle.
    static func lineOffset(_ lights: TrafficLights?, barHeight: CGFloat) -> CGFloat {
        guard let lights else { return 0 }
        return lights.centerY - barHeight / 2
    }
}

/// Reports the window's traffic lights whenever AppKit may have moved them: when the view joins the window, when the
/// window resizes or enters and leaves full screen, and when the buttons or their title bar change frame (a toolbar
/// that comes or goes makes the title bar taller or shorter).
struct TrafficLightsReader: NSViewRepresentable {
    let onChange: (TrafficLights?) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (TrafficLights?) -> Void
        private var observers: [NSObjectProtocol] = []
        private var reported: TrafficLights??
        private var isScheduled = false

        init(onChange: @escaping (TrafficLights?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            reported = nil
            guard let window else { return }
            let center = NotificationCenter.default
            let windowEvents: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in windowEvents {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.schedule() }
                    })
            }
            let buttons = [NSWindow.ButtonType.closeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            for view in buttons + buttons.compactMap(\.superview) {
                observers.append(
                    center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.schedule() }
                    })
            }
            schedule()
        }

        /// Reads after the current update: AppKit may still be laying out the title bar, and SwiftUI may be updating
        /// its views, where changing their state would crash.
        private func schedule() {
            guard !isScheduled else { return }
            isScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                isScheduled = false
                guard let window else { return }
                let lights = TrafficLights(window: window)
                guard reported != .some(lights) else { return }
                reported = .some(lights)
                onChange(lights)
            }
        }
    }
}
