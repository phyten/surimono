import AppKit

/// SwiftUI's document group adds the document's Save, Duplicate, Rename, Move To, Revert and Lock items. A viewer never
/// changes the reader's file, and Rename and Move To would rename or move it even though writes are refused. The group
/// cannot be replaced without losing Close and Open Recent too, and the document answers these actions before anything
/// in the window's responder chain is asked, so the items are hidden instead, with their key equivalents off.
enum DocumentEditMenu {
    static let hiddenActions: Set<Selector> = [
        #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)), #selector(NSDocument.saveTo(_:)),
        #selector(NSDocument.duplicate(_:)), #selector(NSDocument.rename(_:)), #selector(NSDocument.move(_:)),
        #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)),
        #selector(NSDocument.lock(_:)), #selector(NSDocument.unlock(_:)),
    ]

    private static var isHiding = false

    static func hideItems(in menu: NSMenu?) {
        // Hiding an item posts a change notification, which would walk the menus again from inside this walk.
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        hide(in: menu)
    }

    private static func hide(in menu: NSMenu?) {
        var previous: NSMenuItem?
        for item in menu?.items ?? [] {
            defer { previous = item }
            if let action = item.action, hiddenActions.contains(action) { conceal(item) }
            guard let submenu = item.submenu else { continue }
            hide(in: submenu)
            // AppKit shows a Revert To submenu, filled with the document's versions when it opens, right after the
            // Revert To Saved item; restoring a version would write the file.
            if previous?.action == #selector(NSDocument.revertToSaved(_:)) { conceal(item) }
        }
    }

    private static func conceal(_ item: NSMenuItem) {
        if item.allowsKeyEquivalentWhenHidden { item.allowsKeyEquivalentWhenHidden = false }
        if !item.isHidden { item.isHidden = true }
    }

    /// SwiftUI builds the menus after launch and adds or updates items again later, so the items are hidden again,
    /// before the menu shows, whenever a menu changes.
    static func startHiding() {
        hideItems(in: NSApp.mainMenu)
        for name in [
            NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                guard Thread.isMainThread else {
                    Task { @MainActor in hideItems(in: NSApp.mainMenu) }
                    return
                }
                MainActor.assumeIsolated { hideItems(in: NSApp.mainMenu) }
            }
        }
    }
}
