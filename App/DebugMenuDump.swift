#if DEBUG
    import AppKit
    import OSLog
    import SurimonoCore

    enum DebugMenuDump {
        private static let destination = DebugSnapshot.argument("SurimonoMenuDump").flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        }
        private static var started = false
        private static var placeholderEvents: [String] = []
        private static var timedSamples = ""
        private static var recentPresentation: String?
        private static var fileTracking: String?
        private static var writeQueued = false

        private static var observations: String {
            (placeholderEvents + [fileTracking, recentPresentation].compactMap { $0 }).map { $0 + "\n" }.joined()
        }

        private static func scheduleWrite() {
            guard let destination, !timedSamples.isEmpty, !writeQueued else { return }
            writeQueued = true
            DispatchQueue.main.async {
                writeQueued = false
                _ = write(timedSamples + observations, to: destination)
            }
        }

        static func recordFileTracking(_ menu: NSMenu, main: NSMenu) {
            guard destination != nil, fileTracking == nil, main.numberOfItems > 1,
                menu === main.item(at: 1)?.submenu
            else { return }
            let titles = [
                String(localized: "Print…"), String(localized: "Print"), String(localized: "Print with System Dialog…"),
            ]
            let printItems = menu.items.filter { titles.contains($0.title) }.map {
                "\($0.title) action=\($0.action.map(NSStringFromSelector) ?? "nil") enabled=\($0.isEnabled)"
            }
            fileTracking = (["First File menu tracking"] + printState() + printItems).joined(separator: "\n")
            scheduleWrite()
        }

        static func recentMenuPresented(_ menu: NSMenu) {
            guard destination != nil, recentPresentation == nil else { return }
            let names = menu.items.compactMap { ($0.representedObject as? URL)?.lastPathComponent }
            recentPresentation =
                "Open Recent at menuNeedsUpdate: files=\(names) clearEnabled=\(menu.items.last?.isEnabled == true)"
            scheduleWrite()
        }

        static func recordPlaceholder(_ item: NSMenuItem, hidden: Bool) {
            guard destination != nil, placeholderEvents.count < 32 else { return }
            placeholderEvents.append(
                "placeholder id=\(ObjectIdentifier(item)) title=\(item.title.debugDescription) hidden=\(hidden) \(identity(item))"
            )
            scheduleWrite()
        }

        private static func identity(_ item: NSMenuItem) -> String {
            let represented =
                item.representedObject.map { String(String(describing: $0).prefix(256)).debugDescription } ?? "nil"
            let attributed = item.attributedTitle?.string.debugDescription ?? "nil"
            let submenu = item.submenu?.title.debugDescription ?? "nil"
            return
                "class=\(NSStringFromClass(type(of: item))) attributedTitle=\(attributed) submenuTitle=\(submenu) representedObject=\(represented)"
        }

        struct Row {
            let title: String
            let identity: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
            let action: Selector?
            let enabled: Bool
            let hidden: Bool
            let separator: Bool
            let children: [Row]

            init(_ item: NSMenuItem) {
                identity = DebugMenuDump.identity(item)
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
                guard write(first + observations, to: destination) else { return }
                timedSamples = first
                guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
                timedSamples += "\n" + describe("Three seconds later")
                _ = write(timedSamples + observations, to: destination)
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

        private static func printState() -> [String] {
            let menus = ShortcutDispatcher.shared.menus
            let state = menus.menuState.snapshot
            let key = NSApp.keyWindow
            let mainWindow = NSApp.mainWindow
            let keyModel = DocumentWindows.shared.model(for: key)
            let visibility = MenuSnapshot.Visibility(model: keyModel, preferences: menus.preferences())
            var lines = [
                "appActive=\(NSApp.isActive) keyWindow=\(key?.windowNumber ?? 0) mainWindow=\(mainWindow?.windowNumber ?? 0) snapshotVersion=\(state.version) trackingDepth=\(menus.updates.trackingDepth)"
            ]
            for window in NSApp.windows where window.isVisible {
                if let model = DocumentWindows.shared.model(for: window) {
                    lines.append(
                        "documentWindow=\(window.windowNumber) mode=\(model.mode) canPerformPrintCommand=\(model.canPerformPrintCommand) canRequestPrint=\(model.canRequestPrint)"
                    )
                }
            }
            for operation in [ShortcutOperationID.documentPrint, .documentPrintSystem] {
                let live = ShortcutDispatcher.isAvailable(operation, model: keyModel, visibility: visibility)
                lines.append(
                    "\(operation.rawValue) SwiftUI.snapshotEnabled=\(state.content.enabled.contains(operation)) keyDocumentEnabled=\(live)"
                )
            }
            return lines
        }

        private static func describe(_ stage: String) -> String {
            var lines = [stage] + printState()
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
                        "\(indent)\(marker)\(title) key=\(item.key.debugDescription) modifiers=\(symbols)(\(mask.rawValue)) action=\(action) enabled=\(item.enabled) \(item.identity)"
                    )
                    append(item.children, indent: indent + "  ")
                }
            }
            if let main = NSApp.mainMenu {
                let file = main.items.dropFirst().first?.submenu
                let header = file?.items.first { !$0.isHidden && $0.title == String(localized: "Open Recent") }
                let delegate = header?.submenu?.delegate.map { String(describing: type(of: $0)) } ?? "nil"
                let urls = NSDocumentController.shared.recentDocumentURLs.map(\.lastPathComponent)
                lines.append("recentDocumentURLs=\(urls) recentMenuDelegate=\(delegate)")
                append(main.items.map(Row.init), indent: "")
            } else {
                lines.append("[no main menu]")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
#endif
