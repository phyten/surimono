import AppKit
import Observation
import SwiftUI

/// Only descriptor-owned rows participate in reconciliation. AppKit keeps its Services, Help and Window entries.
final class ViewerMainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shareIdentifier = "surimono.menu.documentShare"

    /// The native row titles have their own catalog because several differ from labels inside the viewer.
    static func standardTitle(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "MainMenu")
    }

    private unowned let shell: AppKitShell
    private let main = NSMenu()
    private let recent = NSMenu()
    private var sections: [(DocumentMenuDescriptor.Section, Group)] = []
    private let recentSource = RecentDocumentsMenu()
    private var tracked: [NSMenu: Int] = [:]
    private var awaitingClose = false
    var trackingDepth: Int { tracked.values.reduce(0, +) }
    private var installedRows = false
    private var observationArmed = false
    private var refreshing = false
    private var userKeyEquivalents =
        UserDefaults.standard.dictionary(forKey: "NSUserKeyEquivalents") as? [String: String]
    private var lastTextInput = false
    private weak var lastModel: DocumentViewModel?

    private let sharing = FileShareMenu()
    #if DEBUG
        // The host checks the actual rows we installed independently of OS-provided Services,
        // Help search, window-management and input-method rows on its particular macOS version.
        let installedItems = NSHashTable<NSMenuItem>.weakObjects()
        private weak var fileMenu: NSMenu?
        private var recordingFileOpening = false
    #endif

    private final class Group {
        let menu: NSMenu
        let before: NSMenuItem?
        var items: [DocumentMenuDescriptor.ID: NSMenuItem] = [:]
        var children: [DocumentMenuDescriptor.ID: Group] = [:]
        init(_ menu: NSMenu, before: NSMenuItem? = nil) {
            self.menu = menu
            self.before = before
        }
    }

    init(shell: AppKitShell) { self.shell = shell }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        #if DEBUG
            installedItems.add(item)
        #endif
        let menu = NSMenu(title: title)
        item.submenu = menu
        menu.delegate = self
        return menu
    }

    @discardableResult
    private func native(
        _ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        #if DEBUG
            installedItems.add(item)
        #endif
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    func install() {
        guard !installedRows else { return }
        NSMenuItem.usesUserKeyEquivalents = true
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Surimono"
        func appTitle(_ key: String) -> String { String(format: Self.standardTitle(key), appName) }
        let app = submenu(appName, in: main)
        native(app, appTitle("About %@"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        let afterInfo = NSMenuItem.separator()
        app.addItem(afterInfo)
        sections.append((.appInfo, Group(app, before: afterInfo)))
        let settings = native(
            app, Self.standardTitle("Settings…"), #selector(AppKitShell.openSettings(_:)), ",", target: shell)
        ShortcutDispatcher.shared.menus.register(settings, for: .appSettings)
        app.addItem(.separator())
        let services = submenu(Self.standardTitle("Services"), in: app)
        services.delegate = nil
        app.addItem(.separator())
        native(app, appTitle("Hide %@"), #selector(NSApplication.hide(_:)), "h")
        native(
            app, Self.standardTitle("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
            [.option, .command])
        native(app, Self.standardTitle("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        native(app, appTitle("Quit %@"), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(Self.standardTitle("File"), in: main)
        let afterOpen = NSMenuItem.separator()
        file.addItem(afterOpen)
        sections.append((.open, Group(file, before: afterOpen)))
        native(file, Self.standardTitle("Close"), #selector(NSWindow.performClose(_:)), "w")
        let beforeShare = NSMenuItem.separator()
        file.addItem(beforeShare)
        sections.append((.save, Group(file, before: beforeShare)))
        sharing.item.identifier = .init(Self.shareIdentifier)
        file.addItem(sharing.item)
        #if DEBUG
            installedItems.add(sharing.item)
        #endif
        file.addItem(.separator())
        sections.append((.printItems, Group(file)))

        let edit = submenu(Self.standardTitle("Edit"), in: main)
        native(edit, Self.standardTitle("Undo"), #selector(SettingsUndoRouter.undo(_:)), "z")
        native(edit, Self.standardTitle("Redo"), #selector(SettingsUndoRouter.redo(_:)), "z", [.shift, .command])
        edit.addItem(.separator())
        native(edit, Self.standardTitle("Cut"), #selector(NSText.cut(_:)), "x")
        native(edit, Self.standardTitle("Copy"), #selector(NSText.copy(_:)), "c")
        native(edit, Self.standardTitle("Paste"), #selector(NSText.paste(_:)), "v")
        native(edit, Self.standardTitle("Delete"), #selector(NSText.delete(_:)))
        native(edit, Self.standardTitle("Select All"), #selector(NSText.selectAll(_:)), "a")
        sections.append((.edit, Group(edit)))
        let view = submenu(Self.standardTitle("View"), in: main)
        sections.append((.view, Group(view)))
        sections.append((.document, Group(submenu(String(localized: "Document"), in: main))))
        let window = submenu(Self.standardTitle("Window"), in: main)
        native(window, Self.standardTitle("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        native(window, Self.standardTitle("Zoom"), #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        native(window, Self.standardTitle("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        let help = submenu(Self.standardTitle("Help"), in: main)
        sections.append((.help, Group(help)))
        recent.delegate = self
        for (name, selector) in [
            (NSMenu.didBeginTrackingNotification, #selector(began)),
            (NSMenu.didEndTrackingNotification, #selector(ended)),
            (RecentFileHistory.systemListChanged, #selector(sourceChanged)),
            (NSLocale.currentLocaleDidChangeNotification, #selector(sourceChanged)),
            (ClipboardWindows.libraryDidChange, #selector(sourceChanged)),
            (NSApplication.didBecomeActiveNotification, #selector(sourceChanged)),
            (UserDefaults.didChangeNotification, #selector(defaultsChanged)),
            (NSApplication.didUpdateNotification, #selector(focusChanged)),
        ] {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
        }
        refresh()
        NSApp.mainMenu = main
        NSApp.servicesMenu = services
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        ShortcutDispatcher.shared.menus.readKeys(in: main)
        #if DEBUG
            fileMenu = file
        #endif
    }

    @objc private func sourceChanged(_ note: Notification) {
        if note.name == ClipboardWindows.libraryDidChange { observationArmed = false }
        refresh()
    }

    @objc nonisolated private func defaultsChanged(_ note: Notification) {
        // User defaults notifications may arrive on a writer's thread.
        Task { @MainActor in
            let keys = UserDefaults.standard.dictionary(forKey: "NSUserKeyEquivalents") as? [String: String]
            guard keys != self.userKeyEquivalents else { return }
            self.userKeyEquivalents = keys
            self.refresh()
        }
    }

    @objc private func focusChanged(_ note: Notification) {
        let input = ShortcutDispatcher.isTextInput(NSApp.keyWindow?.firstResponder)
        if lastModel !== DocumentWindows.shared.currentModel || input != lastTextInput { refresh() }
    }

    @objc private func began(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        var root = menu
        while let parent = root.supermenu { root = parent }
        guard root === main else { return }
        tracked[menu, default: 0] += 1
    }

    @objc private func ended(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        if menu === main, tracked[main, default: 0] <= 1 {
            // A root end can be the only close notification for several tracked submenus.
            tracked.removeAll()
        } else if let count = tracked[menu] {
            tracked[menu] = count > 1 ? count - 1 : nil
        } else {
            return
        }
        guard tracked.isEmpty else { return }
        awaitingClose = true
        DispatchQueue.main.async {
            self.awaitingClose = false
            self.refresh()
        }
    }

    #if DEBUG
        func menuWillOpen(_ menu: NSMenu) {
            if menu === fileMenu, !recordingFileOpening {
                recordingFileOpening = true
                DebugMenuDump.recordFileTracking(menu, main: main)
                DebugMenuDump.fileWillOpen(menu)
            }
        }

        func menuDidClose(_ menu: NSMenu) {
            if menu === fileMenu, recordingFileOpening {
                DebugMenuDump.fileDidClose(menu)
                fileMenu = nil
            }
        }
    #endif

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        #if DEBUG
            if menu === recent { DebugMenuDump.recentMenuPresented(menu) }
        #endif
    }

    private func content() -> MenuSnapshot.Content {
        // Observe key-window transitions, including to a window without a model.
        _ = DocumentWindows.shared.activeModel
        let model = DocumentWindows.shared.currentModel
        return .init(
            model: model, preferences: shell.environment.preferences,
            library: model?.library ?? ClipboardWindows.shared.library ?? shell.environment.library,
            textInput: ShortcutDispatcher.isTextInput(NSApp.keyWindow?.firstResponder))
    }

    private func refresh() {
        guard tracked.isEmpty, !awaitingClose, !refreshing else { return }
        lastModel = DocumentWindows.shared.currentModel
        lastTextInput = ShortcutDispatcher.isTextInput(NSApp.keyWindow?.firstResponder)
        refreshing = true
        defer { refreshing = false }
        let shortcuts = ShortcutDispatcher.shared.menus
        if installedRows { shortcuts.readKeys(in: main) }
        let next: MenuSnapshot.Content
        if observationArmed {
            next = content()
        } else {
            observationArmed = true
            next = withObservationTracking {
                content()
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.observationArmed = false
                    self?.refresh()
                }
            }
        }
        recentSource.refresh(recent)
        if installedRows, shortcuts.menuState.snapshot.content == next { return }
        shortcuts.menuState.publish(next)
        installedRows = true
        let state = shortcuts.menuState.snapshot
        for (section, group) in sections {
            reconcile(DocumentMenuDescriptor.rows(for: section, in: state), in: group)
        }
        if NSApp.mainMenu === main { shortcuts.readKeys(in: main) }
    }

    /// Walk backwards so an insertion can use the next surviving owned row as its anchor.
    private func reconcile(_ rows: [DocumentMenuDescriptor], in group: Group) {
        let ids = Set(rows.map(\.id))
        for (id, item) in group.items where !ids.contains(id) {
            group.menu.removeItem(item)
            group.items.removeValue(forKey: id)
            group.children.removeValue(forKey: id)
        }
        var anchor = group.before.flatMap { $0.menu === group.menu ? $0 : nil }
        for row in rows.reversed() {
            let item: NSMenuItem
            if let existing = group.items[row.id] {
                item = existing
            } else {
                if case .divider = row.id { item = .separator() } else { item = NSMenuItem() }
                group.items[row.id] = item
                #if DEBUG
                    installedItems.add(item)
                #endif
            }
            if !item.isSeparatorItem { configure(item, row: row, group: group) }
            var position = anchor.map { group.menu.index(of: $0) } ?? group.menu.numberOfItems
            if item.menu == nil {
                group.menu.insertItem(item, at: position)
            } else if anchor != nil, group.menu.index(of: item) >= position {
                group.menu.removeItem(item)
                position = anchor.map { group.menu.index(of: $0) } ?? group.menu.numberOfItems
                group.menu.insertItem(item, at: position)
            }
            anchor = item
        }
    }

    private func configure(_ item: NSMenuItem, row: DocumentMenuDescriptor, group: Group) {
        let title: String
        switch row.title {
        case .key(let key): title = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        case .verbatim(let value): title = value
        case .replaceSetting(let name): title = String(localized: "Replace “\(name)” with Current Settings")
        }
        if item.title != title { item.title = title }
        if item.subtitle != row.subtitle { item.subtitle = row.subtitle }
        let state: NSControl.StateValue = row.checked == true ? .on : .off
        if item.state != state { item.state = state }
        switch row.id {
        case .action(let action):
            item.representedObject = row
            if item.target == nil {
                item.target = self
                item.action = #selector(invoke(_:))
                if case .operation(let operation) = action {
                    ShortcutDispatcher.shared.menus.register(item, for: operation)
                    let id = SystemMenuShortcuts.accessibilityID(operation)
                    item.identifier = .init(id)
                    item.setAccessibilityIdentifier(id)
                }
            }
            let key = row.shortcut.map { String($0.key.character) } ?? ""
            let mask = row.shortcut?.modifiers.nsEventFlags ?? []
            let automatic =
                row.operation.map {
                    $0 == .appOpen
                        || ShortcutDispatcher.shared.menus.menuState.snapshot.content.automaticMenuKeys[$0] != nil
                } ?? false
            if item.allowsAutomaticKeyEquivalentLocalization != automatic {
                item.allowsAutomaticKeyEquivalentLocalization = automatic
            }
            if item.allowsAutomaticKeyEquivalentMirroring != automatic {
                item.allowsAutomaticKeyEquivalentMirroring = automatic
            }
            if item.userKeyEquivalent.isEmpty {
                if item.keyEquivalent != key { item.keyEquivalent = key }
                if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
            }
            if item.isEnabled != row.isEnabled { item.isEnabled = row.isEnabled }
        case .recentDocuments:
            if item.submenu == nil {
                item.identifier = .init(RecentDocumentsMenu.identifier)
                recent.title = title
                item.submenu = recent
            }
        case .menu, .typefacePicker:
            if item.isEnabled != row.isEnabled { item.isEnabled = row.isEnabled }
            let child = group.children[row.id] ?? Group(NSMenu(title: title))
            if item.submenu == nil {
                group.children[row.id] = child
                item.submenu = child.menu
                child.menu.delegate = self
            }
            reconcile(row.children, in: child)
        case .divider: break
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let row = item.representedObject as? DocumentMenuDescriptor, case .action(let action) = row.id else {
            return false
        }
        return ShortcutDispatcher.shared.canPerform(action)
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let row = sender.representedObject as? DocumentMenuDescriptor,
            case .action(let action) = row.id
        else { return }
        action.perform(preferences: shell.environment.preferences)
    }
}

extension EventModifiers {
    fileprivate var nsEventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
