import AppKit
import Observation
import SwiftUI

/// Only descriptor-owned rows participate in reconciliation. AppKit keeps its Services, Help and Window entries.
final class ViewerMainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
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
    private var picker: NSSharingServicePicker?
    #if DEBUG
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
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    func install() {
        let app = submenu("Surimono", in: main)
        native(app, String(localized: "About Surimono"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        let afterInfo = NSMenuItem.separator()
        app.addItem(afterInfo)
        sections.append((.appInfo, Group(app, before: afterInfo)))
        native(app, String(localized: "Settings…"), #selector(AppKitShell.showSettings(_:)), ",", target: shell)
        app.addItem(.separator())
        let services = submenu(String(localized: "Services"), in: app)
        services.delegate = nil
        app.addItem(.separator())
        native(app, String(localized: "Hide Surimono"), #selector(NSApplication.hide(_:)), "h")
        native(
            app, String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
            [.option, .command])
        native(app, String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        native(app, String(localized: "Quit Surimono"), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(String(localized: "File"), in: main)
        let afterOpen = NSMenuItem.separator()
        file.addItem(afterOpen)
        sections.append((.open, Group(file, before: afterOpen)))
        native(file, String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w")
        native(file, String(localized: "Share") + "…", #selector(share(_:)), target: self)
            .identifier = .init(DocumentShareMenu.identifier)
        file.addItem(.separator())
        sections.append((.printItems, Group(file)))

        let edit = submenu(String(localized: "Edit"), in: main)
        native(edit, String(localized: "Undo"), Selector(("undo:")), "z")
        native(edit, String(localized: "Redo"), Selector(("redo:")), "z", [.shift, .command])
        edit.addItem(.separator())
        native(edit, String(localized: "Cut"), #selector(NSText.cut(_:)), "x")
        native(edit, String(localized: "Copy"), #selector(NSText.copy(_:)), "c")
        native(edit, String(localized: "Paste"), #selector(NSText.paste(_:)), "v")
        native(
            edit, String(localized: "Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v",
            [.option, .shift, .command])
        native(edit, String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")
        sections.append((.edit, Group(edit)))
        let view = submenu(String(localized: "View"), in: main)
        let afterView = NSMenuItem.separator()
        view.addItem(afterView)
        sections.append((.view, Group(view, before: afterView)))
        native(
            view, String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
            [.command, .control])
        sections.append((.document, Group(submenu(String(localized: "Document"), in: main))))
        let window = submenu(String(localized: "Window"), in: main)
        native(window, String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        native(window, String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        native(window, String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        let help = submenu(String(localized: "Help"), in: main)
        sections.append((.help, Group(help)))
        recent.delegate = self
        for (name, selector) in [
            (NSMenu.didBeginTrackingNotification, #selector(began)),
            (NSMenu.didEndTrackingNotification, #selector(ended)),
            (RecentFileHistory.systemListChanged, #selector(historyChanged(_:))),
        ] {
            NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
        }
        refresh()
        NSApp.mainMenu = main
        NSApp.servicesMenu = services
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        #if DEBUG
            fileMenu = file
        #endif
    }

    @objc private func historyChanged(_ note: Notification) { refresh() }

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
        return .init(
            model: DocumentWindows.shared.currentModel, preferences: shell.environment.preferences,
            library: shell.environment.library,
            textInput: ShortcutDispatcher.isTextInput(NSApp.keyWindow?.firstResponder))
    }

    private func refresh() {
        guard tracked.isEmpty, !awaitingClose, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
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
        let shortcuts = ShortcutDispatcher.shared.menus
        if installedRows { shortcuts.readKeys(in: main) }
        if installedRows, shortcuts.menuState.snapshot.content == next { return }
        shortcuts.menuState.publish(next)
        installedRows = true
        let state = shortcuts.menuState.snapshot
        for (section, group) in sections {
            reconcile(DocumentMenuDescriptor.rows(for: section, in: state), in: group)
        }
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
            if item.keyEquivalent != key { item.keyEquivalent = key }
            if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
            if item.isEnabled != row.isEnabled { item.isEnabled = row.isEnabled }
        case .recentDocuments:
            if item.submenu == nil {
                item.identifier = .init(RecentDocumentsMenu.identifier)
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
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
        if item.action == #selector(share(_:)) {
            guard let model = DocumentWindows.shared.currentModel else { return false }
            return !model.sourceURLs.isEmpty || model.canExportReading(.png)
        }
        guard let row = item.representedObject as? DocumentMenuDescriptor else { return false }
        if let operation = row.operation {
            let model = DocumentWindows.shared.currentModel
            return ShortcutDispatcher.isAvailable(
                operation, model: model, visibility: .init(model: model, preferences: shell.environment.preferences))
        }
        return row.isEnabled
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let row = sender.representedObject as? DocumentMenuDescriptor,
            case .action(let action) = row.id
        else { return }
        action.perform(preferences: shell.environment.preferences)
    }

    @objc private func share(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let model = DocumentWindows.shared.currentModel,
            let view = model.window?.contentView
        else { return }
        let urls = model.fileURL.map { [$0] } ?? model.sourceURLs
        guard !urls.isEmpty else {
            model.exportReading(.share)
            return
        }
        let picker = NSSharingServicePicker(items: urls)
        self.picker = picker
        picker.show(
            relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view,
            preferredEdge: .minY)
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
