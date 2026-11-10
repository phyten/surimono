import AppKit
import SurimonoCore
import SwiftUI

/// Where the tray's scroll view is scrolled to, as it last told.
struct TrayScrollState: Equatable {
    /// Where the scroll view's top-left corner is in the content.
    var offset: CGPoint = .zero
    /// How far the scroll view reaches up under the bar above the tray; at the top, the offset is minus this.
    var topInset: CGFloat = 0
}

/// The tray's zoom and scroll position, which the zoom buttons, the menus' ⌘+, ⌘− and ⌘0, pinches, ⌘-scrolls,
/// double-clicks and drags all change. A zoom keeps one spot where it is: the spot under the pointer, or the middle
/// of the tray for the buttons and keys.
@MainActor @Observable final class TrayZoomer {
    private(set) var zoom: CGFloat = 1
    var position = ScrollPosition(edge: .top)
    /// What the tray was last laid out from, apart from the zoom. When it changes, as when the window is resized or the
    /// sheets are made again, the spot at the top of the visible area stays where it is, so the sheet being looked at
    /// stays in view.
    @ObservationIgnored var context: TrayGeometry.Context? {
        didSet {
            guard let context, context != oldValue else { return }
            guard let oldValue else {
                if let row = pendingRow {
                    pendingRow = nil
                    show(row: row, animated: false)
                }
                return
            }
            let old = TrayGeometry(context: oldValue, zoom: zoom)
            // A larger window fits larger sheets and lowers the limit of the zoom; the zoom follows, or the first
            // step back out would change nothing.
            let zoom = TrayGeometry(context: context, zoom: 1).metrics.clampedZoom(zoom)
            let new = TrayGeometry(context: context, zoom: zoom)
            let spot = CGPoint(x: old.viewportSize.width / 2, y: scroll.topInset)
            apply(
                zoom: zoom,
                offset: new.offset(keeping: spot, scrolledTo: scroll.offset, in: old, topInset: scroll.topInset))
        }
    }
    /// A row asked for before the tray was first laid out.
    @ObservationIgnored private var pendingRow: Int?
    /// It changes with every step of a scroll, so it is not observed.
    @ObservationIgnored var scroll = TrayScrollState()

    private var fitted: TrayMetrics? { context.map { TrayGeometry(context: $0, zoom: 1).metrics } }

    var canZoomIn: Bool { zoom < (fitted?.maximumZoom ?? TrayMetrics.fittedZoomLimit) - 0.001 }
    var canZoomOut: Bool { zoom > TrayMetrics.minimumZoom + 0.001 }

    func zoomIn() { setZoom(zoom * TrayMetrics.zoomStep, keeping: nil) }
    func zoomOut() { setZoom(zoom / TrayMetrics.zoomStep, keeping: nil) }
    func zoomToFit() { setZoom(1, keeping: nil) }

    /// A double-click or a two-finger double-tap: twice the fitted size around the spot, or back to fitting.
    func toggleZoom(keeping spot: CGPoint) { setZoom(abs(zoom - 1) < 0.001 ? 2 : 1, keeping: spot) }

    /// A step of a pinch or of a ⌘-scroll, by `factor`.
    func magnify(by factor: CGFloat, keeping spot: CGPoint) { setZoom(zoom * factor, keeping: spot) }

    /// The point of the scroll view over `point` of the content.
    func spot(ofContentPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - scroll.offset.x, y: point.y - scroll.offset.y)
    }

    /// - Parameter spot: The point of the scroll view to keep over the same place on the sheets; nil for the middle of
    ///   its visible area.
    func setZoom(_ value: CGFloat, keeping spot: CGPoint?) {
        guard let context else {
            zoom = min(max(value, TrayMetrics.minimumZoom), TrayMetrics.fittedZoomLimit)
            return
        }
        let old = TrayGeometry(context: context, zoom: zoom)
        let target = old.metrics.clampedZoom(value)
        guard abs(target - zoom) > 0.0001 else { return }
        let new = TrayGeometry(context: context, zoom: target)
        let spot = spot ?? CGPoint(x: old.viewportSize.width / 2, y: scroll.topInset + old.viewportSize.height / 2)
        apply(
            zoom: target,
            offset: new.offset(keeping: spot, scrolledTo: scroll.offset, in: old, topInset: scroll.topInset))
    }

    /// The new size and the new position go to the scroll view together, so the sheets do not jump in between.
    private func apply(zoom: CGFloat, offset: CGPoint) {
        guard zoom != self.zoom || offset != scroll.offset else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if zoom != self.zoom { self.zoom = zoom }
            position.scrollTo(point: positionPoint(offset))
        }
        scroll.offset = offset
    }

    /// Scrolls to `offset`, or as near to it as the tray goes.
    func scroll(to offset: CGPoint) {
        guard let context else { return }
        let offset = TrayGeometry(context: context, zoom: zoom).clamped(offset, topInset: scroll.topInset)
        guard offset != scroll.offset else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(point: positionPoint(offset)) }
        scroll.offset = offset
    }

    /// The navigator's up and down: `row` at the top of the visible area.
    func show(row: Int, animated: Bool) {
        guard let context else {
            pendingRow = row
            return
        }
        let offset = TrayGeometry(context: context, zoom: zoom).offset(
            showingRow: row, topInset: scroll.topInset, x: scroll.offset.x)
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(point: positionPoint(offset)) }
        } else {
            position.scrollTo(point: positionPoint(offset))
        }
        scroll.offset = offset
    }

    /// A scroll position measures from where the scroll view rests at its top, below the inset, while the scroll
    /// view's offset measures from its corner.
    private func positionPoint(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: offset.x, y: offset.y + scroll.topInset)
    }

    /// A new layout starts at the top, fitted.
    func reset() {
        zoom = 1
        position.scrollTo(edge: .top)
        scroll.offset = CGPoint(x: 0, y: -scroll.topInset)
    }
}

/// The tray's content under the pointer: a drag moves the sheets like paper on a desk when they do not fit the window,
/// a double-click zooms to twice the fitted size around the spot and back as on the paper of the view mode, and
/// pinches and ⌘-scrolls go to `TrayGestureMonitor`.
struct TrayPanning: ViewModifier {
    let zoomer: TrayZoomer
    let canPan: Bool
    @State private var start: CGPoint?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background { TrayGestureMonitor(zoomer: zoomer) }
            .gesture(drag)
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    zoomer.toggleZoom(keeping: zoomer.spot(ofContentPoint: value.location))
                }
            )
            .pointerStyle(canPan ? (start == nil ? .grabIdle : .grabActive) : nil)
    }

    private var drag: some Gesture {
        // In the window's coordinates, which stay put while the sheets move under the pointer.
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard canPan else { return }
                let start = start ?? zoomer.scroll.offset
                if self.start == nil { self.start = start }
                zoomer.scroll(
                    to: CGPoint(x: start.x - value.translation.width, y: start.y - value.translation.height))
            }
            .onEnded { _ in start = nil }
    }
}

/// Tells the zoomer where the tray is scrolled to, and the navigator which sheet is at the top.
struct TrayScrollReport: ViewModifier {
    let zoomer: TrayZoomer
    let geometry: TrayGeometry
    @Binding var currentRow: Int

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: TrayScrollState.self) { scroll in
                TrayScrollState(offset: scroll.contentOffset, topInset: scroll.contentInsets.top)
            } action: { _, scroll in
                zoomer.scroll = scroll
            }
            .onScrollGeometryChange(for: Int.self) { scroll in
                geometry.rowIndex(atTop: scroll.contentOffset.y + scroll.contentInsets.top)
            } action: { _, row in
                currentRow = row
            }
    }
}

/// Takes the pinches, smart zooms and ⌘-scrolls over the tray before its scroll view does. It lies behind the
/// tray's content, which gives it the content's coordinates, and never takes a click itself.
struct TrayGestureMonitor: NSViewRepresentable {
    let zoomer: TrayZoomer

    func makeNSView(context: Context) -> TrayGestureMonitorView {
        let view = TrayGestureMonitorView()
        view.zoomer = zoomer
        return view
    }

    func updateNSView(_ view: TrayGestureMonitorView, context: Context) { view.zoomer = zoomer }
}

final class TrayGestureMonitorView: NSView {
    weak var zoomer: TrayZoomer?
    private var monitor: Any?
    private var wheelSequence = WheelSequence()
    /// A pinch that began over the tray, which keeps it to its end, as the paper of the view mode does.
    private var pinchActive = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            wheelSequence = WheelSequence()
            pinchActive = false
            return
        }
        guard monitor == nil else { return }
        // The scroll view would take pinches and ⌘-scrolls for itself; these are the tray's.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify, .scrollWheel]) {
            [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .magnify:
            guard event.window === window, let zoomer else { return false }
            if event.phase.contains(.began) { pinchActive = isOverTray(windowPoint: event.locationInWindow) }
            let owned = pinchActive || (event.phase.isEmpty && isOverTray(windowPoint: event.locationInWindow))
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { pinchActive = false }
            guard owned else { return false }
            zoomer.magnify(
                by: 1 + event.magnification,
                keeping: zoomer.spot(ofContentPoint: convert(event.locationInWindow, from: nil)))
        case .smartMagnify:
            guard let spot = spot(of: event) else { return false }
            zoomer?.toggleZoom(keeping: spot)
        case .scrollWheel:
            return handleWheel(event)
        default:
            return false
        }
        return true
    }

    /// A ⌘-scroll that starts over the tray is the tray's to its end, glide included, even if ⌘ is let go or the
    /// pointer moves over a panel, so that the rest of it does not scroll the sheets; one that starts elsewhere is never
    /// taken over. Only the steps under the fingers with ⌘ held zoom.
    private func handleWheel(_ event: NSEvent) -> Bool {
        let phase = Self.phase(of: event)
        let command = event.modifierFlags.intersection([.command, .option, .control]) == [.command]
        let decision = wheelSequence.update(
            phase: phase, timestamp: event.timestamp,
            startsOnPaper: command && event.window === window && isOverTray(windowPoint: event.locationInWindow))
        guard decision.owns, event.window === window, let zoomer else { return false }
        if command, phase != .momentum, phase != .momentumEnded {
            let spot = zoomer.spot(ofContentPoint: convert(event.locationInWindow, from: nil))
            zoomer.magnify(by: exp(event.scrollingDeltaY * 0.01), keeping: spot)
        }
        return true
    }

    /// As the paper of the view mode reads it (`PaperPDFView.handleWheelEvent`).
    private static func phase(of event: NSEvent) -> WheelPageTurner.Phase {
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { return .momentumEnded }
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.cancelled) { return .cancelled }
        if event.phase.contains(.ended) { return .ended }
        if event.phase.contains(.began) { return .began }
        return event.phase.isEmpty ? .discrete : .changed
    }

    /// Where the event is in the tray's scroll view, or nil when it is not over the tray itself: the monitor sees
    /// every event of the window, and those over the panels and controls laid over the tray are theirs.
    func spot(of event: NSEvent) -> CGPoint? {
        guard event.window === window, let zoomer, isOverTray(windowPoint: event.locationInWindow) else { return nil }
        return zoomer.spot(ofContentPoint: convert(event.locationInWindow, from: nil))
    }

    func isOverTray(windowPoint: NSPoint) -> Bool {
        guard let scrollView = enclosingScrollView, let content = window?.contentView else { return false }
        let location = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = content.hitTest(location) else { return false }
        return hit === scrollView || hit.isDescendant(of: scrollView)
    }
}
