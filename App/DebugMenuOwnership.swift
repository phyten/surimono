#if DEBUG
    import AppKit

    /// A passive recorder for -SurimonoMenuDump. The backing row table preserves the removed item's identity.
    final class DebugMenuOwnership: NSObject {
        private struct Entry: Equatable {
            let id: ObjectIdentifier
            let title: String
            let submenu: ObjectIdentifier?
            var label: String { "\(id) \(title.debugDescription) submenu=\(String(describing: submenu))" }
        }

        static let shared = DebugMenuOwnership()
        private var rows: [ObjectIdentifier: [Entry]] = [:]
        private weak var installing: NSMenu?
        private var inspecting = false
        private var launched = false
        private var events: [String] = []
        private var changed: (() -> Void)?
        var transcript: String { events.joined(separator: "\n") + "\n" }

        func start(onChange: @escaping () -> Void) {
            changed = onChange
            for name in [
                NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification,
            ] {
                NotificationCenter.default.addObserver(self, selector: #selector(notified(_:)), name: name, object: nil)
            }
            // AppKit explicitly omits remove notifications for this bulk operation.
            if let bulk = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.removeAllItems)),
                let tap = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.surimonoDumpRemoveAllItems))
            {
                method_exchangeImplementations(bulk, tap)
            }
        }

        func didLaunch() {
            launched = true
            record("applicationDidFinishLaunching")
        }

        func setting(from old: NSMenu?, to new: NSMenu?) {
            installing = new
            record(
                "setMainMenu: \(String(describing: old.map(ObjectIdentifier.init))) -> \(String(describing: new.map(ObjectIdentifier.init)))"
            )
            rows.removeAll()
            if let new { seed(new) }
        }

        private func seed(_ menu: NSMenu) {
            rows[ObjectIdentifier(menu)] = entries(menu)
            for item in menu.items { if let child = item.submenu { seed(child) } }
        }

        private func entries(_ menu: NSMenu) -> [Entry] {
            menu.items.map {
                Entry(id: ObjectIdentifier($0), title: $0.title, submenu: $0.submenu.map(ObjectIdentifier.init))
            }
        }

        @objc private func notified(_ note: Notification) {
            if let menu = note.object as? NSMenu { compare(menu, reason: note.name.rawValue) }
        }

        func compare(_ menu: NSMenu, reason: String) {
            guard !inspecting else { return }
            var root = menu
            while let parent = root.supermenu { root = parent }
            guard root === installing || root === NSApp?.mainMenu else { return }
            inspecting = true
            defer { inspecting = false }
            let id = ObjectIdentifier(menu)
            let before = rows[id] ?? []
            let now = entries(menu)
            rows[id] = now
            // A title or enabled-state change alone is presentation, not a structural edit.
            let diff = now.map(\.id).difference(from: before.map(\.id))
            var details: [String] = []
            for change in diff {
                switch change {
                case .remove(let index, _, _): details.append("remove[\(index)] " + before[index].label)
                case .insert(let index, _, _):
                    details.append("insert[\(index)] " + now[index].label)
                    if let child = menu.item(at: index)?.submenu { seed(child) }
                }
            }
            for (index, entry) in now.enumerated() {
                if let prior = before.first(where: { $0.id == entry.id }), prior.submenu != entry.submenu {
                    details.append("setSubmenu[\(index)] \(prior.label) -> \(entry.label)")
                    if let child = menu.item(at: index)?.submenu { seed(child) }
                }
            }
            if !details.isEmpty {
                record("\(reason) \(menu.title.debugDescription) \(id) " + details.joined(separator: " | "))
            }
        }

        private func record(_ event: String) {
            let stack = Thread.callStackSymbols.dropFirst(2).prefix(20).joined(separator: "\n    ")
            events.append(
                "\(events.count + 1) uptime=\(ProcessInfo.processInfo.systemUptime) phase=\(launched ? "running" : "launch") \(event)\n    \(stack)"
            )
            changed?()
        }
    }

    extension NSMenu {
        @objc fileprivate dynamic func surimonoDumpRemoveAllItems() {
            surimonoDumpRemoveAllItems()
            DebugMenuOwnership.shared.compare(self, reason: "removeAllItems")
        }
    }
#endif
