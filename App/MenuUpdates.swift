import AppKit
import Observation
import SurimonoCore

/// One boundary for the document-group hider, shortcut adapter, and SwiftUI command presentation.
final class MenuUpdates: NSObject {
    let state: MenuState
    private(set) lazy var hider = DocumentEditMenu(
        canScan: { [weak self] in self?.allowsWrites == true },
        isTracking: { [weak self] in self?.tracked.isEmpty == false })
    private let inventory = MenuTraceInventory()
    let root: () -> NSMenu?
    let model: () -> DocumentViewModel?
    let preferences: () -> AppPreferences?
    let lifecycle: NotificationCenter
    private let marginUnit: () -> MarginUnit
    private let apply: (NSMenu) -> Void
    private var tracked: Set<NSMenu> = []
    private weak var trackingRoot: NSMenu?
    private var trackingLoopDepth = 0
    private var idleObserver: CFRunLoopObserver?
    private var queued = false
    private var dirty = false
    private var awaitingEndPass = false
    var allowsWrites: Bool { tracked.isEmpty && !awaitingEndPass }
    private var applying = false
    private var started = false
    private var pendingStop: (() -> Void)?
    private weak var lastMenu: NSMenu?
    private weak var observedPreferences: AppPreferences?
    private weak var observedModel: DocumentViewModel?
    private weak var observedLibrary: UserLibrary?
    private var localeObserver: NSObjectProtocol?
    private var observation = 0
    private var snapshotDirty = true
    private var observationArmed = false

    init(
        state: MenuState, root: @escaping () -> NSMenu?, model: @escaping () -> DocumentViewModel?,
        preferences: @escaping () -> AppPreferences?, lifecycle: NotificationCenter,
        marginUnit: @escaping () -> MarginUnit = { .current }, apply: @escaping (NSMenu) -> Void
    ) {
        self.state = state
        self.root = root
        self.model = model
        self.preferences = preferences
        self.lifecycle = lifecycle
        self.marginUnit = marginUnit
        self.apply = apply
    }

    func start() {
        pendingStop = nil
        guard !started else { return }
        started = true
        snapshotDirty = true
        MenuTrace.start()
        if MenuTrace.enabled, let menu = root() { inventory.seed(menu) }
        for name in [
            NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged), name: name, object: nil)
        }
        for name in [
            NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification, NSApplication.didUpdateNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification, NSWindow.willCloseNotification,
        ] {
            lifecycle.addObserver(self, selector: #selector(windowChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyChanged), name: ClosedClipboardDocuments.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowChanged), name: ClipboardWindows.libraryDidChange,
            object: ClipboardWindows.shared)
        // Saved setting descriptions include the measurement unit of the current locale.
        localeObserver = lifecycle.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) {
            [weak self] _ in MainActor.assumeIsolated { self?.invalidateSnapshot("locale") }
        }
        runPass(refreshSnapshot: true)
        schedule()
    }

    func stop(restore: @escaping () -> Void) {
        // Restoring target/action is a mutation too. Leave the observer installed until the last end arrives.
        if !allowsWrites {
            pendingStop = restore
            return
        }
        // Native restoration may itself deliver a begin notification. Keep observing through the last setter.
        let wasApplying = applying
        applying = true
        restore()
        applying = wasApplying
        guard allowsWrites else {
            pendingStop = restore
            return
        }
        started = false
        dirty = false
        observation += 1
        observationArmed = false
        snapshotDirty = true
        NotificationCenter.default.removeObserver(self)
        lifecycle.removeObserver(self)
        if let localeObserver { lifecycle.removeObserver(localeObserver) }
        localeObserver = nil
    }

    @objc private func windowChanged(_ note: Notification) {
        let main = root()
        if !tracked.isEmpty {
            // A rebuilt root or detached submenu cannot still own the application's menu bar.
            tracked = tracked.filter { Self.top(of: $0) === main }
            if tracked.isEmpty || trackingRoot !== main {
                finishTracking("tree replaced")
            }
        }
        if note.name == NSApplication.didUpdateNotification {
            // A focus handoff can finish after its notifications. Inspect the settled identity on the next turn.
            if sourcesChanged { invalidateSnapshot("focus") }
            guard allowsWrites, !applying, main !== lastMenu || hider.hasExposedFileItems(in: main) else { return }
            reconcile()
            schedule()
        } else {
            // In particular, willClose still names the outgoing window; resolve the key window after AppKit returns.
            invalidateSnapshot(note.name.rawValue)
        }
    }

    @objc private func historyChanged(_ note: Notification) {
        guard let owner = note.object as? AppPreferences, owner === preferences() else { return }
        invalidateSnapshot("clipboard-history")
    }

    private var sourcesChanged: Bool {
        let current = model()
        return current !== observedModel || preferences() !== observedPreferences
            || (current?.library ?? ClipboardWindows.shared.library) !== observedLibrary
    }

    private func invalidateSnapshot(_ source: String) {
        MenuTrace.record("invalidate source=\(source) version=\(state.snapshot.version)")
        snapshotDirty = true
        schedule()
    }

    private static func top(of menu: NSMenu) -> NSMenu {
        var top = menu
        while let parent = top.supermenu { top = parent }
        return top
    }

    private static func hasHighlight(in menu: NSMenu) -> Bool {
        menu.highlightedItem != nil
            || menu.items.contains {
                guard let submenu = $0.submenu else { return false }
                return hasHighlight(in: submenu)
            }
    }

    isolated deinit {
        if let localeObserver { lifecycle.removeObserver(localeObserver) }
        if let idleObserver { CFRunLoopObserverInvalidate(idleObserver) }
    }

    private func watchForIdleMenuBar() {
        guard idleObserver == nil else { return }
        // A modal menu can service the main queue and can even enter a nested default loop.
        // Only an idle default loop outside those tracking frames provides evidence of a missed end.
        trackingLoopDepth = RunLoop.main.currentMode == .eventTracking ? 1 : 0
        let phases: CFRunLoopActivity = [.entry, .exit, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, phases.rawValue, true, 0) { [weak self] _, phase in
            MainActor.assumeIsolated {
                guard let self, let main = self.trackingRoot else { return }
                let mode = RunLoop.main.currentMode
                if mode == .eventTracking {
                    if phase == .entry { self.trackingLoopDepth += 1 }
                    if phase == .exit { self.trackingLoopDepth = max(0, self.trackingLoopDepth - 1) }
                } else if phase == .beforeWaiting, mode == .default, self.trackingLoopDepth == 0,
                    !Self.hasHighlight(in: main)
                {
                    self.finishTracking("idle menu bar")
                }
            }
        }
        idleObserver = observer
        let loop = CFRunLoopGetMain()
        CFRunLoopAddObserver(loop, observer, .defaultMode)
        CFRunLoopAddObserver(loop, observer, CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
    }

    private func finishTracking(_ recovery: String? = nil) {
        if let recovery { MenuTrace.record("tracking recovered: \(recovery) version=\(state.snapshot.version)") }
        if let idleObserver { CFRunLoopObserverInvalidate(idleObserver) }
        idleObserver = nil
        tracked.removeAll()
        trackingRoot = nil
        awaitingEndPass = true
        schedule()
    }

    @objc private func menuChanged(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        if note.name == NSMenu.didEndTrackingNotification {
            guard tracked.contains(menu) else { return }
            MenuTrace.record(
                "end menu=\(MenuTrace.menuName(menu, root: trackingRoot)) depth=\(tracked.count) version=\(state.snapshot.version)"
            )
            tracked.remove(menu)
            // The root's end also closes any child whose individual end was lost.
            if menu === trackingRoot || tracked.isEmpty { finishTracking() }
            return
        }
        guard let main = root(), Self.top(of: menu) === main else { return }
        if note.name == NSMenu.didBeginTrackingNotification {
            let startsSession = tracked.isEmpty || trackingRoot !== main
            if startsSession {
                tracked.removeAll()
                trackingRoot = main
                watchForIdleMenuBar()
            }
            tracked.insert(menu)
            dirty = true
            MenuTrace.record(
                "begin menu=\(MenuTrace.menuName(menu, root: main)) depth=\(tracked.count) version=\(state.snapshot.version)"
            )
            if MenuTrace.enabled { inventory.seed(menu, reportVisibleEditsAt: state.snapshot.version) }
        } else {
            if MenuTrace.enabled {
                let line = inventory.change(
                    note, in: menu, root: main, depth: tracked.count, version: state.snapshot.version)
                MenuTrace.record(line)
            }
            // Record the incoming instance before its synchronous repair emits nested change notifications.
            hider.hideNotifiedItem(note, in: menu, main: main)
            // Our setters post changes too. A structural edit, even during a pass, requires another look.
            if !applying || note.name != NSMenu.didChangeItemNotification { schedule() }
        }
    }

    private func schedule() {
        dirty = true
        guard started, tracked.isEmpty, !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            guard started else { return }
            guard tracked.isEmpty else {
                dirty = true
                return
            }
            awaitingEndPass = false
            if let restore = pendingStop {
                pendingStop = nil
                stop(restore: restore)
            } else if dirty || snapshotDirty {
                runPass(refreshSnapshot: true, deferred: true)
            }
        }
    }

    func reconcile() {
        guard allowsWrites else {
            dirty = true
            return
        }
        if started, sourcesChanged { invalidateSnapshot("model") }
        runPass(refreshSnapshot: !started)
    }

    private func runPass(refreshSnapshot: Bool, deferred: Bool = false) {
        guard allowsWrites, !applying else { return }
        applying = true
        defer {
            applying = false
            // A nested AppKit loop may service our queued pass while another pass is still on the stack.
            if started, allowsWrites, dirty || snapshotDirty { schedule() }
        }
        // An immediate shortcut reconciliation cannot consume queued work that may still need the key table.
        if deferred { dirty = false }
        if refreshSnapshot { refreshState() }
        guard allowsWrites, let menu = root() else { return }
        lastMenu = menu
        apply(menu)
        if allowsWrites { hider.hideItems(in: root(), clearHiddenKeys: deferred) }
    }

    private func refreshState() {
        guard snapshotDirty || sourcesChanged else { return }
        snapshotDirty = false
        func read() -> MenuSnapshot.Content {
            // Registration can finish after the key-window notification for this same window.
            _ = DocumentWindows.shared.activeModel
            let current = model()
            return MenuSnapshot.Content(
                model: current, preferences: preferences(),
                library: current?.library ?? ClipboardWindows.shared.library, marginUnit: marginUnit()
            )
        }
        // Repeated key/main notifications for the same sources should not accumulate one-shot observers.
        if observationArmed, !sourcesChanged, read() == state.snapshot.content { return }
        observedModel = model()
        observedLibrary = observedModel?.library ?? ClipboardWindows.shared.library
        observedPreferences = preferences()
        observation += 1
        observationArmed = true
        let generation = observation
        let facts = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // All sources are main-actor models. Observation fires before storage changes, so only enqueue here.
            MainActor.assumeIsolated {
                guard let self, self.observation == generation else { return }
                self.observationArmed = false
                self.invalidateSnapshot("observation")
            }
        }
        guard allowsWrites else {
            snapshotDirty = true
            return
        }
        state.publish(facts)
    }
}
