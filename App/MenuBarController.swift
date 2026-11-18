import AppKit
import SurimonoCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let recentURLs: () -> [URL]
    private(set) var item: NSStatusItem?

    init(preferences: AppPreferences, recentURLs: @escaping () -> [URL] = { RecentFileHistory.welcomeURLs }) {
        self.recentURLs = recentURLs
        super.init()
        preferences.menuBarVisibilityDidChange = { [weak self] in self?.setVisible($0) }
        setVisible(preferences.showsMenuBarItem)
    }

    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let glyph = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Surimono")
            glyph?.isTemplate = true
            status.button?.image = glyph
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            menu.delegate = self
            status.menu = menu
            item = status
        } else if !visible {
            remove()
        }
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(.clipboardOpen, to: menu)
        add(.clipboardOpenPrintScreen, to: menu)
        add(.appStreamingPreview, to: menu)
        menu.addItem(.separator())
        let urls = recentURLs().prefix(8)
        for url in urls {
            let entry = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        add(.appOpen, to: menu)
        add(.appSettings, to: menu)
    }

    private func add(_ operation: ShortcutOperationID, to menu: NSMenu) {
        let entry = menu.addItem(withTitle: ShortcutText.name(operation), action: #selector(run), keyEquivalent: "")
        entry.target = self
        entry.representedObject = operation.rawValue
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let operation = ShortcutOperationID(rawValue: id) else {
            return
        }
        NSApp.activate()
        ShortcutDispatcher.shared.perform(operation)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.activate()
        OpenRouter.shared.openRecent(url)
    }
}
