import AppKit

/// SwiftUI's document group adds the document's Save, Duplicate, Rename, Move To, Revert and Lock items. A viewer never
/// changes the reader's file, and Rename and Move To would rename or move it even though writes are refused. Keep the
/// native group so Share and Open Recent still work, and leave key-equivalent setters out of item notifications.
final class DocumentEditMenu {
    private let canScan: () -> Bool
    private let isTracking: () -> Bool
    private var notifiedItem: NSMenuItem?
    private(set) lazy var writes = MenuWrites(
        canWrite: { [weak self] in self?.notifiedItem != nil || self?.canScan() == true },
        isTracking: isTracking)

    init(canScan: @escaping () -> Bool = { true }, isTracking: @escaping () -> Bool = { false }) {
        self.canScan = canScan
        self.isTracking = isTracking
    }

    static let hiddenActions: Set<Selector> = [
        #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
        #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
        #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)),
        #selector(NSDocument.lock(_:)), #selector(NSDocument.unlock(_:)),
    ]

    private static let versionsTitle = Bundle(for: NSDocument.self).localizedString(
        forKey: "Revert To", value: "Revert To", table: "MenuCommands")

    static func protects(_ item: NSMenuItem, after previous: NSMenuItem?) -> Bool {
        if let action = item.action, hiddenActions.contains(action) { return true }
        // An empty versions submenu has no browseVersions: child until AppKit fills it.
        return item.submenu != nil && previous?.action == #selector(NSDocument.revertToSaved(_:))
            && (item.action == nil || item.action == NSSelectorFromString("submenuAction:"))
            && item.identifier?.rawValue.hasPrefix("surimono.shortcut.") != true
            && (item.title == versionsTitle || item.title == "Revert To" || item.title == "バージョンを戻す"
                || item.submenu?.items.contains(where: { $0.action == #selector(NSDocument.browseVersions(_:)) })
                    == true)
    }

    func hasExposedFileItems(in main: NSMenu?) -> Bool {
        guard !MenuTrace.noHider, let main, main.numberOfItems > 1, let file = main.item(at: 1)?.submenu else {
            return false
        }
        var previous: NSMenuItem?
        for item in file.items {
            if Self.protects(item, after: previous),
                !item.isHidden || item.isAlternate || item.allowsKeyEquivalentWhenHidden
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
            let item = menu.item(at: index), item !== notifiedItem,
            Self.protects(item, after: index > 0 ? menu.item(at: index - 1) : nil),
            Self.isInFileMenu(menu, of: main)
        else { return }
        // Each setter can notify recursively. A different item added during the repair still needs its own pass.
        let previous = notifiedItem
        notifiedItem = item
        defer { notifiedItem = previous }
        conceal(item)
    }

    func hideItems(in menu: NSMenu?) {
        guard !MenuTrace.noHider, notifiedItem == nil, canScan() else { return }
        var previous: NSMenuItem?
        for item in menu?.items ?? [] {
            if Self.protects(item, after: previous) {
                conceal(item)
            }
            if let submenu = item.submenu { hideItems(in: submenu) }
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
