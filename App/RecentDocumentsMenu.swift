import AppKit

/// SwiftUI declares the submenu in File. AppKit asks for its contents immediately before display,
/// including when the document controller's list changed without a notification to this process.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    static let identifier = "surimono.menu.openRecent"
    private static let title = String(localized: "Open Recent")
    private static let openTitle = String(localized: "Open…")
    private let urls: () -> [URL]
    private let open: (URL) -> Void
    private let clear: () -> Void

    init(
        urls: @escaping () -> [URL] = { NSDocumentController.shared.recentDocumentURLs },
        open: @escaping (URL) -> Void = { OpenRouter.shared.openRecent($0) },
        clear: @escaping () -> Void = { NSDocumentController.shared.clearRecentDocuments(nil) }
    ) {
        self.urls = urls
        self.open = open
        self.clear = clear
    }

    /// SwiftUI does not propagate the accessibility identifier on every OS. The declared pair also
    /// identifies our header: the system's Open Recent follows the native openDocument: action.
    func bind(in file: NSMenu, at index: Int) -> NSMenu? {
        guard (0..<file.numberOfItems).contains(index), let item = file.item(at: index),
            item.title == Self.title, !item.isHidden, let menu = item.submenu,
            !DocumentEditMenu.protects(item, after: nil)
        else { return nil }
        let previous = index > 0 ? file.item(at: index - 1) : nil
        guard
            item.accessibilityIdentifier() == Self.identifier
                || (previous?.title == Self.openTitle && previous?.isHidden == false && previous?.action != nil
                    && previous?.action != #selector(NSDocumentController.openDocument(_:)))
        else { return nil }
        if menu.delegate !== self { menu.delegate = self }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(menu)
        #if DEBUG
            DebugMenuDump.recentMenuPresented(menu)
        #endif
    }

    func refresh(_ menu: NSMenu) {
        let current = urls()
        let items = menu.items
        if let last = items.last, last.target === self, last.action == #selector(clearMenu),
            items.count == current.count + (current.isEmpty ? 1 : 2),
            last.isEnabled == !current.isEmpty,
            zip(items, current).allSatisfy({ $0.target === self && $0.representedObject as? URL == $1 })
        {
            return
        }
        menu.autoenablesItems = false
        menu.removeAllItems()
        for url in current {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openFile), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
        if !current.isEmpty { menu.addItem(.separator()) }
        let item = menu.addItem(
            withTitle: String(localized: "Clear Menu"), action: #selector(clearMenu), keyEquivalent: "")
        item.target = self
        item.isEnabled = !current.isEmpty
    }

    @objc private func openFile(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc private func clearMenu(_ sender: NSMenuItem) { clear() }
}
