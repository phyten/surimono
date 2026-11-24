import AppKit

/// SwiftUI's document group adds the document's Save, Duplicate, Rename, Move To, Revert and Lock items. A viewer never
/// changes the reader's file, and Rename and Move To would rename or move it even though writes are refused. Keep the
/// native group for Share, and leave key-equivalent setters out of item notifications.
final class DocumentEditMenu {
    private let canScan: () -> Bool
    private let isTracking: () -> Bool
    private var notifiedItem: NSMenuItem?
    private weak var installedFileMenu: NSMenu?
    private let hiddenPlaceholders = NSHashTable<NSMenuItem>.weakObjects()
    private(set) lazy var writes = MenuWrites(
        canWrite: { [weak self] in self?.notifiedItem != nil || self?.canScan() == true },
        isTracking: isTracking)

    init(canScan: @escaping () -> Bool = { true }, isTracking: @escaping () -> Bool = { false }) {
        self.canScan = canScan
        self.isTracking = isTracking
    }

    static let hiddenActions: Set<Selector> = [
        #selector(NSDocumentController.openDocument(_:)),
        #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
        #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
        #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)),
        #selector(NSDocument.lock(_:)), #selector(NSDocument.unlock(_:)),
    ]

    private static let versionsTitle = Bundle(for: NSDocument.self).localizedString(
        forKey: "Revert To", value: "Revert To", table: "MenuCommands")

    static func protects(_ item: NSMenuItem, after previous: NSMenuItem?) -> Bool {
        if let action = item.action, hiddenActions.contains(action) { return true }
        if let submenu = item.submenu, isSystemRecentMenu(submenu) { return true }
        // An empty versions submenu has no browseVersions: child until AppKit fills it.
        return item.submenu != nil && previous?.action == #selector(NSDocument.revertToSaved(_:))
            && (item.action == nil || item.action == NSSelectorFromString("submenuAction:"))
            && item.identifier?.rawValue.hasPrefix("surimono.shortcut.") != true
            && (item.title == versionsTitle || item.title == "Revert To" || item.title == "バージョンを戻す"
                || item.submenu?.items.contains(where: { $0.action == #selector(NSDocument.browseVersions(_:)) })
                    == true)
    }

    // AppKit uses this selector even when the recent list is empty. Our submenu targets
    // RecentDocumentsMenu for Clear Menu, so it can always be distinguished from the system's.
    private static let clearRecent = #selector(NSDocumentController.clearRecentDocuments(_:))

    private static func isSystemRecentMenu(_ menu: NSMenu) -> Bool {
        menu.identifier?.rawValue == "_NSRecentDocumentsMenuName"
            || (menu.numberOfItems > 0 && menu.item(at: menu.numberOfItems - 1)?.action == clearRecent)
    }

    func hasExposedFileItems(in main: NSMenu?) -> Bool {
        guard !MenuTrace.noHider, let main, main.numberOfItems > 1, let file = main.item(at: 1)?.submenu else {
            return false
        }
        var previous: NSMenuItem?
        for item in file.items {
            if !item.isHidden || item.isAlternate || item.allowsKeyEquivalentWhenHidden,
                Self.protects(item, after: previous)
            {
                return true
            }
            previous = item
        }
        return false
    }

    static func isInFileMenu(_ menu: NSMenu?, of main: NSMenu?) -> Bool {
        guard let main, main.numberOfItems > 1, let file = main.item(at: 1)?.submenu else { return false }
        var ancestor = menu
        while let current = ancestor {
            if current === file { return true }
            ancestor = current.supermenu
        }
        return false
    }

    func hideNotifiedItem(_ note: Notification, in menu: NSMenu, main: NSMenu) {
        guard !MenuTrace.noHider,
            note.name == NSMenu.didAddItemNotification || note.name == NSMenu.didChangeItemNotification,
            let index = note.userInfo?["NSMenuItemIndex"] as? Int, (0..<menu.numberOfItems).contains(index),
            let changed = menu.item(at: index)
        else { return }
        if menu === main, index == 1, let file = changed.submenu, file !== installedFileMenu {
            // SwiftUI can attach a fully built File menu. Its earlier child notifications had no main-menu ancestor.
            installedFileMenu = file
            var previous: NSMenuItem?
            for item in file.items {
                if Self.protects(item, after: previous) { concealNotified(item) } else { updatePlaceholder(item) }
                previous = item
            }
            return
        }
        let item: NSMenuItem
        if changed.action == Self.clearRecent, let parent = menu.supermenu,
            main.numberOfItems > 1, parent === main.item(at: 1)?.submenu,
            let owner = parent.items.first(where: { $0.submenu === menu })
        {
            // A submenu can be attached before AppKit installs its Clear Menu child.
            item = owner
        } else {
            guard Self.protects(changed, after: index > 0 ? menu.item(at: index - 1) : nil) else {
                if main.numberOfItems > 1, main.item(at: 1)?.submenu === menu { updatePlaceholder(changed) }
                return
            }
            item = changed
        }
        guard Self.isInFileMenu(menu, of: main) else { return }
        concealNotified(item)
    }

    private func concealNotified(_ item: NSMenuItem) {
        guard item !== notifiedItem else { return }
        // Each setter can notify recursively. A different item added during the repair still needs its own pass.
        let previous = notifiedItem
        notifiedItem = item
        defer { notifiedItem = previous }
        conceal(item)
    }

    // A newly allocated NSMenuItem has this literal title. Only File's top level has exclusively
    // command names; a recent document or a user-defined preset can legitimately have the same name.
    private func updatePlaceholder(_ item: NSMenuItem) {
        guard item !== notifiedItem else { return }
        let placeholder =
            item.title == "NSMenuItem"
            && (item.attributedTitle?.string.isEmpty != false || item.attributedTitle?.string == "NSMenuItem")
        if placeholder {
            guard !item.isHidden else { return }
            hiddenPlaceholders.add(item)
        } else {
            guard hiddenPlaceholders.contains(item) else { return }
            hiddenPlaceholders.remove(item)
        }
        let previous = notifiedItem
        notifiedItem = item
        defer { notifiedItem = previous }
        #if DEBUG
            DebugMenuDump.recordPlaceholder(item, hidden: placeholder)
        #endif
        writes.set(item, \.isHidden, "isHidden", placeholder)
    }

    func hideItems(in menu: NSMenu?, fileLevel: Bool = true) {
        guard !MenuTrace.noHider, notifiedItem == nil, canScan() else { return }
        var previous: NSMenuItem?
        for item in menu?.items ?? [] {
            if Self.protects(item, after: previous) {
                conceal(item)
            } else if fileLevel {
                updatePlaceholder(item)
            }
            if let submenu = item.submenu, !(submenu.delegate is RecentDocumentsMenu) {
                hideItems(in: submenu, fileLevel: false)
            }
            previous = item
        }
    }

    private func conceal(_ item: NSMenuItem) {
        // AppKit can hold its key-equivalent lock while notifying. Dissolve the alternate pair here so
        // Duplicate cannot appear in place of its primary while the menu is on screen.
        writes.set(item, \.isAlternate, "isAlternate", false)
        writes.set(item, \.allowsKeyEquivalentWhenHidden, "allowsKeyEquivalentWhenHidden", false)
        writes.set(item, \.isHidden, "isHidden", true)
    }
}
