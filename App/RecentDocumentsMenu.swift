import AppKit

/// Populates the submenu owned by ViewerMainMenu and keeps surviving URL rows in place.
final class RecentDocumentsMenu: NSObject {
    static let identifier = "surimono.menu.openRecent"
    private let urls: () -> [URL]
    private let open: (URL) -> Void
    private let clear: () -> Void

    init(
        urls: @escaping () -> [URL] = {
            RecentFileHistory.shared?.visibleURLs ?? NSDocumentController.shared.recentDocumentURLs
        },
        open: @escaping (URL) -> Void = { OpenRouter.shared.openRecent($0) },
        clear: @escaping () -> Void = { NSDocumentController.shared.clearRecentDocuments(nil) }
    ) {
        self.urls = urls
        self.open = open
        self.clear = clear
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
        var files: [URL: NSMenuItem] = [:]
        for item in items where item.target === self {
            if let url = item.representedObject as? URL { files[url] = item }
        }
        var desired = current.map { url -> NSMenuItem in
            if let existing = files.removeValue(forKey: url) { return existing }
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openFile), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            return item
        }
        if !current.isEmpty { desired.append(items.first(where: \.isSeparatorItem) ?? .separator()) }
        let clear =
            items.first { $0.target === self && $0.action == #selector(clearMenu) }
            ?? NSMenuItem(title: String(localized: "Clear Menu"), action: #selector(clearMenu), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !current.isEmpty
        desired.append(clear)
        for item in items where !desired.contains(item) { menu.removeItem(item) }
        for (index, item) in desired.enumerated() where menu.index(of: item) != index {
            if item.menu === menu { menu.removeItem(item) }
            menu.insertItem(item, at: index)
        }
    }

    @objc private func openFile(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url) }
    }

    @objc private func clearMenu(_ sender: NSMenuItem) { clear() }
}
