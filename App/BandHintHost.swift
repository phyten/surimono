import AppKit
import SwiftUI

/// Deadlines use the supplied monotonic instant. Only a card that actually appeared warms the next target.
struct BandHintTiming {
    private(set) var target: String?
    private(set) var visible: String?
    private(set) var deadline: ContinuousClock.Instant?

    private var warmUntil: ContinuousClock.Instant?

    mutating func enter(_ id: String?, at now: ContinuousClock.Instant) {
        advance(to: now)
        guard target != id else { return }
        target = id
        if let id {
            if visible == id {
                deadline = nil
            } else {
                visible = nil
                let warm = warmUntil.map { now <= $0 } == true
                deadline = now + .milliseconds(warm ? 60 : 450)
            }
        } else {
            deadline = visible == nil ? nil : now + .milliseconds(150)
        }
    }

    mutating func advance(to now: ContinuousClock.Instant) {
        guard let deadline, now >= deadline else { return }
        visible = target
        if visible != nil { warmUntil = now + .milliseconds(1500) }
        self.deadline = nil
    }

    mutating func dismiss(continuingFocus: Bool = false) {
        if !continuingFocus { warmUntil = nil }
        visible = nil
        deadline = nil
    }
}

private struct BandHintTarget: Equatable {
    let rect: CGRect
    let content: BandHintContent
    let above: Bool
    let showsName: Bool
}

private struct BandHintTargets: PreferenceKey {
    static let defaultValue: [String: BandHintTarget] = [:]
    static func reduce(value: inout [String: BandHintTarget], nextValue: () -> [String: BandHintTarget]) {
        value.merge(nextValue(), uniquingKeysWith: { _, current in current })
    }
}

extension EnvironmentValues {
    @Entry var bandHints: BandHintSession? = nil
    @Entry var hintsAboveBand = false
}

/// Only the real band's segments publish hit rectangles. The grouped control remains one hint target.
enum BandSegment: Hashable { case single, spread, web, paper }

private struct BandSegmentRects: PreferenceKey {
    static let defaultValue: [BandSegment: CGRect] = [:]
    static func reduce(value: inout [BandSegment: CGRect], nextValue: () -> [BandSegment: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, rect in rect })
    }
}

struct BandSegmentInteraction: ViewModifier {
    let segment: BandSegment
    @Environment(\.bandHints) private var session

    func body(content: Content) -> some View {
        if let session {
            content
                .environment(\.bandPartHovered, session.hoveredSegment == segment)
                .environment(\.bandSegmentPressed, session.pressedSegment == segment)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BandSegmentRects.self, value: [segment: proxy.frame(in: .named("band-hint-host"))])
                    }
                }
        } else {
            content
        }
    }
}

extension FocusedValues {
    @Entry fileprivate var bandHintID: String?
}

extension View {
    func bandTurnFocus(forward: Bool) -> some View {
        focusedValue(\.bandHintID, forward ? "pageTurn.next" : "pageTurn.previous")
    }

    /// Installed on the visible control only, outside the measured item.
    func bandHint(
        _ id: String, _ content: BandHintContent, above: Bool = false, enabled: Bool = true, showsName: Bool = false
    ) -> some View {
        focusedValue(\.bandHintID, enabled ? id : nil)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: BandHintTargets.self,
                        value: !enabled
                            ? [:]
                            : [
                                id: BandHintTarget(
                                    rect: geometry.frame(in: .named("band-hint-host")), content: content, above: above,
                                    showsName: showsName)
                            ])
                }
            }
    }
}

/// The bridge only spans the facing edges. Clamping a card near a window corner can offset its centre.
nonisolated struct BandHintFootprint: Equatable, Sendable {
    let id: String
    let rect: CGRect

    func contains(_ point: CGPoint, from source: CGRect) -> Bool {
        if rect.contains(point) { return true }
        let below = rect.midY >= source.midY
        let start = below ? source.maxY : source.minY
        let end = below ? rect.minY : rect.maxY
        guard start != end else { return false }
        let t = (point.y - start) / (end - start)
        guard (0...1).contains(t) else { return false }
        let left = source.minX + (rect.minX - source.minX) * t
        let right = source.maxX + (rect.maxX - source.maxX) * t
        return left <= point.x && point.x <= right
    }
}

@Observable
final class BandHintSession {
    @ObservationIgnored private var segmentRects: [BandSegment: CGRect] = [:]
    private(set) var hoveredSegment: BandSegment?
    private(set) var pressedSegment: BandSegment?
    private(set) var hover: String?
    private(set) var visible: String?
    private var timing = BandHintTiming()
    @ObservationIgnored private var footprint: BandHintFootprint?
    private var overHint = false

    func setFootprint(_ value: BandHintFootprint) {
        guard footprint != value else { return }
        footprint = value
        refresh()
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    fileprivate private(set) var targets: [String: BandHintTarget] = [:]
    @ObservationIgnored private var point: CGPoint?
    fileprivate private(set) var menuDepth = 0
    private(set) var dragging = false
    private(set) var blocked = false
    fileprivate var focus: String?
    private var usingFocus = false
    @ObservationIgnored private var awaitsInput = false
    @ObservationIgnored private var dismissedTarget: String?
    private var mouseFocus = false
    @ObservationIgnored var reduceMotion = false

    var holdsBand: Bool {
        hover != nil || overHint || (!mouseFocus && focus.flatMap { targets[$0] } != nil)
    }

    func move(to position: CGPoint?) {
        if point != position {
            usingFocus = false
            if let position, let dismissedTarget, let source = targets[dismissedTarget],
                source.rect.contains(position)
                    || (footprint?.id == dismissedTarget && footprint?.contains(position, from: source.rect) == true)
            {
                awaitsInput = true
            } else {
                // A menu can still be tracking when the pointer leaves its button.
                if dismissedTarget != nil && timing.visible == nil && timing.deadline == nil {
                    timing.enter(nil, at: .now)
                }
                dismissedTarget = nil
                awaitsInput = false
            }
        }
        point = position
        updateHoveredSegment()
        refresh()
    }

    fileprivate func updateSegments(_ rects: [BandSegment: CGRect]) {
        segmentRects = rects
        updateHoveredSegment()
    }

    private func updateHoveredSegment() {
        let segment = point.flatMap { point in segmentRects.first { $0.value.contains(point) }?.key }
        if segment != hoveredSegment { hoveredSegment = segment }
    }

    fileprivate func update(_ newTargets: [String: BandHintTarget]) {
        if targets != newTargets { targets = newTargets }
        refresh()
    }

    func beginDrag() {
        dragging = true
        dismiss()
    }

    func moveInEditor(to point: CGPoint?, dragging: Bool) {
        self.dragging = dragging
        if !dragging { move(to: point) }
    }

    func setFocus(_ id: String?) {
        focus = id
        guard !mouseFocus else { return }
        if NSEvent.pressedMouseButtons == 0 { dragging = false }
        if id != nil { awaitsInput = false }
        usingFocus = id != nil
        refresh()
    }

    func setBlocked(_ value: Bool) {
        blocked = value
        if value { dismiss() } else { refresh() }
    }

    func menuBegan() {
        menuDepth += 1
        dismiss()
    }

    func menuEnded() {
        menuDepth = max(0, menuDepth - 1)
        if menuDepth == 0 { refresh() }
    }

    private func refresh() {
        let hit = point.flatMap { p in targets.first { $0.value.rect.contains(p) }?.key }
        if hover != hit { hover = hit }
        let resting: String?
        if let point, let visible, let footprint, footprint.id == visible,
            let target = targets[visible], footprint.contains(point, from: target.rect)
        {
            resting = visible
        } else {
            resting = nil
        }
        if overHint != (resting != nil) { overHint = resting != nil }
        // In the editor a card can overlap another chip. Keep its own description until the pointer leaves its face.
        let onFace = point.map { footprint?.rect.contains($0) == true } == true && resting != nil
        let id = usingFocus ? focus.flatMap { targets[$0] == nil ? nil : $0 } : (onFace ? resting : hit ?? resting)
        guard !blocked, !dragging, !awaitsInput, menuDepth == 0, id != timing.target else { return }
        task?.cancel()
        timing.enter(id, at: .now)
        publish()
        guard let deadline = timing.deadline else { return }
        task = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self else { return }
            timing.advance(to: .now)
            publish()
        }
    }

    private func publish() {
        guard visible != timing.visible else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: timing.visible == nil ? 0.06 : 0.08)) {
            visible = timing.visible
        }
    }

    func handle(_ type: NSEvent.EventType, keyCode: UInt16? = nil) {
        switch type {
        case .leftMouseUp:
            pressedSegment = nil
            dragging = false
        case .leftMouseDown:
            mouseFocus = true
            pressedSegment = hoveredSegment
            dismiss()
        case .keyDown:
            mouseFocus = false
            dismiss(continuingFocus: keyCode == 48)
        default:
            mouseFocus = true
            dismiss()
        }
    }

    func dismiss(continuingFocus: Bool = false) {
        awaitsInput = true
        task?.cancel()
        dismissedTarget = hover ?? (overHint ? visible : dismissedTarget)
        timing.dismiss(continuingFocus: continuingFocus)
        visible = nil
        overHint = false
    }

    func reset() {
        dismiss()
        timing = BandHintTiming()
        dismissedTarget = nil
        footprint = nil
        targets = [:]
        segmentRects = [:]
        hoveredSegment = nil
        pressedSegment = nil
        hover = nil
        point = nil
        focus = nil
        dragging = false
        usingFocus = false
        awaitsInput = false
        mouseFocus = false
        menuDepth = 0
    }
}

struct BandHintHost: ViewModifier {
    let session: BandHintSession
    var editor = false
    var blocked = false
    @FocusedValue(\.bandHintID) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .environment(\.bandHints, session)
            .onPreferenceChange(BandSegmentRects.self) { session.updateSegments($0) }
            .onPreferenceChange(BandHintTargets.self) { session.update($0) }
            .overlay {
                if !editor { BandHintLayer(session: session) }
            }
            .coordinateSpace(name: "band-hint-host")
            .background { BandHintEvents(session: session) }
            .onChange(of: focus) { _, id in session.setFocus(id) }
            .onChange(of: blocked, initial: true) { _, value in session.setBlocked(value) }
            .onChange(of: reduceMotion, initial: true) { _, value in session.reduceMotion = value }
            .onDisappear { session.reset() }
    }
}

/// Settings hosts its retained editor in a separate NSHostingView. Its bounds are relayed by the
/// split view so a card can extend across the sidebar without crossing the window edge.
struct BandHintLayer: View {
    let session: BandHintSession
    var editorFrame: CGRect?
    private var editor: Bool { editorFrame != nil }

    private var forced: String? {
        if editor {
            return BandDesign.argument("SurimonoArrangementEditor")?.split(separator: ",")
                .first { $0.hasPrefix("hint:") }.map { String($0.dropFirst(5)) }
        }
        return BandDesign.argument("SurimonoBandHint")
    }

    var body: some View {
        if !session.blocked && !session.dragging && session.menuDepth == 0, let id = forced ?? session.visible,
            let target = session.targets[id] ?? (id == "pageTurn" ? session.targets["pageTurn.next"] : nil)
        {
            let rect = target.rect.offsetBy(dx: editorFrame?.minX ?? 0, dy: editorFrame?.minY ?? 0)
            BandHintPlacement(rect: rect, above: target.above, canFlip: editor) {
                BandHintCard(content: target.content, showName: !target.showsName)
                    .onGeometryChange(for: BandHintFootprint.self) {
                        BandHintFootprint(
                            id: id,
                            rect: $0.frame(in: .named("band-card-layer"))
                                .offsetBy(dx: -(editorFrame?.minX ?? 0), dy: -(editorFrame?.minY ?? 0)))
                    } action: {
                        session.setFootprint($0)
                    }
            }
            .coordinateSpace(name: "band-card-layer")
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A window-local cancellation listener never consumes the event destined for the paper or its controls.
private struct BandHintEvents: NSViewRepresentable {
    let session: BandHintSession

    final class Listener: NSView {
        weak var session: BandHintSession?
        private var monitor: Any?
        private var menus: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in menus { NotificationCenter.default.removeObserver(observer) }
            menus = []
            guard let newWindow else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .leftMouseDragged,
                .leftMouseUp,
            ]) {
                [weak self, weak newWindow] event in
                if event.window === newWindow {
                    self?.session?.handle(event.type, keyCode: event.type == .keyDown ? event.keyCode : nil)
                }
                return event
            }
            let center = NotificationCenter.default
            for name in [
                NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification,
            ] {
                let isMenu = name == NSMenu.didBeginTrackingNotification || name == NSMenu.didEndTrackingNotification
                menus.append(
                    center.addObserver(forName: name, object: isMenu ? nil : newWindow, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let session = self?.session else { return }
                            if name == NSMenu.didBeginTrackingNotification {
                                session.menuBegan()
                            } else if name == NSMenu.didEndTrackingNotification {
                                session.menuEnded()
                            } else {
                                session.dismiss()
                            }
                        }
                    })
            }
        }
    }

    func makeNSView(context: Context) -> Listener {
        let listener = Listener()
        listener.session = session
        return listener
    }
    func updateNSView(_ view: Listener, context: Context) {}
}

/// The retained settings pane and the navigation overlay have separate hosting views. AppKit window coordinates
/// give them the same origin even when the title bar changes the safe area of just one host.
struct BandHintWindowFrame: NSViewRepresentable {
    @Binding var frame: CGRect

    final class Probe: NSView {
        var report: ((CGRect) -> Void)?
        private var pending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }
        override func layout() {
            super.layout()
            schedule()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            schedule()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            schedule()
        }

        func schedule() {
            guard !pending, window != nil else { return }
            pending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                pending = false
                guard window != nil else { return }
                let position = convert(bounds, to: nil)
                report?(CGRect(x: position.minX, y: -position.maxY, width: position.width, height: position.height))
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.report = { if frame != $0 { frame = $0 } }
        view.schedule()
    }
}
