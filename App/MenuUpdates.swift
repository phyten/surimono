import AppKit
import Observation
import SurimonoCore

/// One boundary for the document-group hider, read-only shortcut observer, and SwiftUI command presentation.
final class MenuUpdates: NSObject {
    let state: MenuState
    private(set) lazy var hider = DocumentEditMenu(
        canScan: { [weak self] in self?.allowsWrites == true },
        isTracking: { [weak self] in self?.sessions.isEmpty == false })
    private let inventory = MenuTraceInventory()
    let root: () -> NSMenu?
    let model: () -> DocumentViewModel?
    let preferences: () -> AppPreferences?
    let lifecycle: NotificationCenter
    private let textInput: () -> Bool
    private var observedTextInput = false
    private let controller: ShortcutController
    private let marginUnit: () -> MarginUnit
    private let apply: (NSMenu) -> Void
    // Retain each originating tree through its end, including while SwiftUI installs a different main menu.
    private var sessions: [NSMenu: [NSMenu: Int]] = [:]
    var trackingDepth: Int { sessions.values.reduce(0) { $0 + $1.values.reduce(0, +) } }
    private var queued = false
    private var dirty = false
    private var awaitingEndPass = false
    var allowsWrites: Bool { sessions.isEmpty && !awaitingEndPass }
    private var applying = false
    private var started = false
    private var pendingStop = false
    private weak var lastMenu: NSMenu?
    private weak var observedPreferences: AppPreferences?
    private weak var observedModel: DocumentViewModel?
    private weak var observedLibrary: UserLibrary?
    private var localeObserver: NSObjectProtocol?
    private var observation = 0
    private var recentURLs: [URL] = []
    private var recentURLsDirty = true
    private var snapshotDirty = true
    private var observationArmed = false

    init(
        state: MenuState, root: @escaping () -> NSMenu?, model: @escaping () -> DocumentViewModel?,
        preferences: @escaping () -> AppPreferences?, lifecycle: NotificationCenter,
        controller: ShortcutController = .shared, textInput: @escaping () -> Bool = { false },
        marginUnit: @escaping () -> MarginUnit = { .current },
        apply: @escaping (NSMenu) -> Void
    ) {
        self.state = state
        self.root = root
        self.model = model
        self.preferences = preferences
        self.lifecycle = lifecycle
        self.textInput = textInput
        self.controller = controller
        self.marginUnit = marginUnit
        self.apply = apply
    }

    func start() {
        pendingStop = false
        guard !started else { return }
        started = true
        recentURLsDirty = true
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(recentDocumentsChanged), name: RecentFileHistory.systemListChanged, object: nil)
        runPass()
        schedule()
    }

    func stop() {
        guard allowsWrites else {
            pendingStop = true
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
        if note.name == NSApplication.didFinishLaunchingNotification
            || note.name == NSApplication.didBecomeActiveNotification
        {
            recentURLsDirty = true
        }
        let main = root()
        if note.name == NSApplication.didUpdateNotification {
            // A focus handoff can finish after its notifications. Inspect the settled identity on the next turn.
            if sourcesChanged { invalidateSnapshot("focus") }
            guard !applying, main !== lastMenu || (allowsWrites && hider.hasExposedFileItems(in: main)) else { return }
            if !sessions.isEmpty, main !== lastMenu { MenuTrace.record("main menu replaced with tracking outstanding") }
            schedule()
        } else {
            // In particular, willClose still names the outgoing window; resolve the key window after AppKit returns.
            invalidateSnapshot(note.name.rawValue)
        }
    }

    @objc private func recentDocumentsChanged(_ notification: Notification) {
        recentURLsDirty = true
        invalidateSnapshot("recent documents")
    }

    @objc private func historyChanged(_ note: Notification) {
        guard let owner = note.object as? AppPreferences, owner === preferences() else { return }
        invalidateSnapshot("clipboard-history")
    }

    private var sourcesChanged: Bool {
        let current = model()
        return current !== observedModel || preferences() !== observedPreferences || textInput() != observedTextInput
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

    isolated deinit {
        if let localeObserver { lifecycle.removeObserver(localeObserver) }
    }

    @objc private func menuChanged(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        if note.name == NSMenu.didEndTrackingNotification {
            // A root end closes its children even if only their begin was delivered. Repeated root begins
            // need matching ends; an unrelated or ambiguous end is never evidence that tracking stopped.
            let roots = sessions.keys.filter { $0 === menu || sessions[$0]?[menu] != nil }
            guard roots.count == 1, let origin = roots.first, var depths = sessions[origin] else {
                if !sessions.isEmpty { MenuTrace.record("unmatched end depth=\(trackingDepth)") }
                return
            }
            MenuTrace.record(
                "end menu=\(MenuTrace.menuName(menu, root: origin)) depth=\(trackingDepth) version=\(state.snapshot.version)"
            )
            if menu === origin, depths[menu, default: 0] <= 1 {
                sessions.removeValue(forKey: origin)
            } else {
                let count = depths[menu, default: 0] - 1
                if count > 0 { depths[menu] = count } else { depths.removeValue(forKey: menu) }
                sessions[origin] = depths.isEmpty ? nil : depths
            }
            if sessions.isEmpty {
                awaitingEndPass = true
                schedule()
            }
            return
        }
        let main = Self.top(of: menu)
        guard main === root() || sessions[main] != nil else { return }
        if note.name == NSMenu.didBeginTrackingNotification {
            if sessions[main]?[menu] != nil { MenuTrace.record("repeated begin depth=\(trackingDepth)") }
            sessions[main, default: [:]][menu, default: 0] += 1
            dirty = true
            MenuTrace.record(
                "begin menu=\(MenuTrace.menuName(menu, root: main)) depth=\(trackingDepth) version=\(state.snapshot.version)"
            )
            if MenuTrace.enabled { inventory.seed(menu, reportVisibleEditsAt: state.snapshot.version) }
        } else {
            if MenuTrace.enabled {
                let line = inventory.change(
                    note, in: menu, root: main, depth: trackingDepth, version: state.snapshot.version)
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
        guard started, sessions.isEmpty, !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            guard started else { return }
            guard sessions.isEmpty else {
                dirty = true
                return
            }
            awaitingEndPass = false
            if pendingStop {
                pendingStop = false
                stop()
            } else if dirty || snapshotDirty {
                runPass()
            }
        }
    }

    private func runPass() {
        guard allowsWrites, !applying else { return }
        applying = true
        defer {
            applying = false
            if started, allowsWrites, dirty || snapshotDirty { schedule() }
        }
        dirty = false
        if let menu = root() {
            lastMenu = menu
            apply(menu)
            if allowsWrites, menu.numberOfItems > 1 { hider.hideItems(in: menu.item(at: 1)?.submenu) }
        }
        if allowsWrites { refreshState() }
    }

    private func refreshState() {
        guard snapshotDirty || sourcesChanged else { return }
        snapshotDirty = false
        if recentURLsDirty {
            recentURLsDirty = false
            recentURLs = NSDocumentController.shared.recentDocumentURLs
        }
        func read() -> MenuSnapshot.Content {
            // Registration can finish after the key-window notification for this same window.
            _ = DocumentWindows.shared.activeModel
            let current = model()
            return MenuSnapshot.Content(
                model: current, preferences: preferences(),
                library: current?.library ?? ClipboardWindows.shared.library, marginUnit: marginUnit(),
                controller: controller, textInput: textInput(), recentURLs: recentURLs
            )
        }
        // Repeated key/main notifications for the same sources should not accumulate one-shot observers.
        if observationArmed, !sourcesChanged, read() == state.snapshot.content { return }
        observedTextInput = textInput()
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
