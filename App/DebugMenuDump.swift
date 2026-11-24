#if DEBUG
    import AppKit
    import OSLog

    enum DebugMenuDump {
        private static let destination = DebugSnapshot.argument("SurimonoMenuDump").flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        }
        private static var started = false

        struct Row {
            let title: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
            let action: Selector?
            let enabled: Bool
            let hidden: Bool
            let separator: Bool
            let children: [Row]

            init(_ item: NSMenuItem) {
                title = item.title
                key = item.keyEquivalent
                modifiers = item.keyEquivalentModifierMask
                action = item.action
                enabled = item.isEnabled
                hidden = item.isHiddenOrHasHiddenAncestor
                separator = item.isSeparatorItem
                children = item.submenu?.items.map(Row.init) ?? []
            }
        }

        private(set) static var testLaunchFile: [Row]?

        static func observeTestLaunch() {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return }
            // Keep values from the first turn after launch; other hosted tests can rebuild the menu before its test runs.
            DispatchQueue.main.async {
                testLaunchFile = NSApp.mainMenu?.items.dropFirst().first?.submenu?.items.map(Row.init)
            }
        }

        static func documentRegistered() {
            guard let destination, !started else { return }
            started = true
            Task { @MainActor in
                while !NSApp.windows.contains(where: { $0.isVisible && DocumentWindows.shared.model(for: $0) != nil }) {
                    guard (try? await Task.sleep(for: .milliseconds(20))) != nil else { return }
                }
                let first = describe("First visible document window")
                guard write(first, to: destination) else { return }
                guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
                _ = write(first + "\n" + describe("Three seconds later"), to: destination)
            }
        }

        private static func write(_ text: String, to url: URL) -> Bool {
            guard
                DocumentViewModel.canExport(
                    to: url, sourceURLs: DocumentWindows.shared.openModels.flatMap(\.sourceURLs))
            else { return false }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                Logger(subsystem: "app.surimono.Surimono", category: "MenuDump").error(
                    "Menu dump write failed: \(error.localizedDescription)")
                return false
            }
        }

        private static func describe(_ stage: String) -> String {
            var lines = [stage]
            func append(_ rows: [Row], indent: String) {
                for item in rows {
                    let mask = item.modifiers
                    let symbols = [
                        (NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
                        (.function, "fn"),
                    ]
                    .filter { mask.contains($0.0) }.map(\.1).joined()
                    let marker = item.hidden ? "[hidden] " : ""
                    let title = item.separator ? "---" : item.title.debugDescription
                    let action = item.action.map(NSStringFromSelector) ?? "nil"
                    lines.append(
                        "\(indent)\(marker)\(title) key=\(item.key.debugDescription) modifiers=\(symbols)(\(mask.rawValue)) action=\(action) enabled=\(item.enabled)"
                    )
                    append(item.children, indent: indent + "  ")
                }
            }
            if let main = NSApp.mainMenu {
                append(main.items.map(Row.init), indent: "")
            } else {
                lines.append("[no main menu]")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
#endif
