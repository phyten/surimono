#if DEBUG
    import AppKit
    import OSLog
    import SurimonoCore

    enum DebugMenuDump {
        private static let destination = DebugSnapshot.argument("SurimonoMenuDump").flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        }
        static func beginOwnershipTrace() {
            guard destination != nil else { return }
            DebugMenuOwnership.shared.start { scheduleWrite() }
        }

        static func willSetMainMenu(from old: NSMenu?, to new: NSMenu?) {
            guard destination != nil else { return }
            DebugMenuOwnership.shared.setting(from: old, to: new)
        }

        static func didLaunch() {
            guard let destination else { return }
            DebugMenuOwnership.shared.didLaunch()
            // Capture a no-document launch as well. An existing destination is only overwritten after
            // document registration checks it against the viewer's source URLs.
            DispatchQueue.main.async {
                guard timedSamples.isEmpty, !FileManager.default.fileExists(atPath: destination.path) else { return }
                timedSamples = describe("First turn after launch")
                scheduleWrite()
            }
        }

        private static var started = false
        private static var fileOpening: String?
        private static var firstRows: [String] = []
        private static var fileBeforeClose: String?
        private static var timedSamples = ""
        private static var recentPresentation: String?
        private static var fileTracking: String?
        private static var writeQueued = false

        private static var observations: String {
            DebugMenuOwnership.shared.transcript
                + [fileTracking, fileOpening, fileBeforeClose, recentPresentation].compactMap { $0 }.map { $0 + "\n" }
                .joined()
        }

        private static func scheduleWrite() {
            guard let destination, !timedSamples.isEmpty, !writeQueued else { return }
            writeQueued = true
            DispatchQueue.main.async {
                writeQueued = false
                _ = write(timedSamples + observations, to: destination)
            }
        }

        static func flush() {
            guard let destination, !timedSamples.isEmpty else { return }
            _ = write(timedSamples + observations, to: destination)
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

        static func fileWillOpen(_ file: NSMenu) {
            guard let destination, fileOpening == nil else { return }
            firstRows = visibleLines(file)
            fileOpening = (["First File menu at menuWillOpen (visible rows)"] + printState() + firstRows)
                .joined(separator: "\n")
            _ = write(timedSamples + observations, to: destination)
        }

        static func fileDidClose(_ file: NSMenu) {
            guard let destination, fileOpening != nil, fileBeforeClose == nil else { return }
            let rows = visibleLines(file)
            if rows != firstRows {
                fileBeforeClose = (["First File menu at menuDidClose (visible rows changed)"] + rows)
                    .joined(separator: "\n")
                _ = write(timedSamples + observations, to: destination)
            }
        }

        private static func visibleLines(_ file: NSMenu) -> [String] {
            visibleFileRows(file, modifiers: NSEvent.modifierFlags).map {
                Row($0, includeChildren: false).line(indent: "  ")
            }
        }

        /// Read only the displayed level. AppKit coalesces separators and swaps alternates
        /// for their primary item when the additional modifier (usually Option) is held.
        static func visibleFileRows(_ menu: NSMenu, modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
            var rows: [NSMenuItem] = []
            var primary: NSMenuItem?
            for item in menu.items where !item.isHiddenOrHasHiddenAncestor {
                if item.isAlternate {
                    if let primary, !rows.isEmpty {
                        let additional = item.keyEquivalentModifierMask.subtracting(primary.keyEquivalentModifierMask)
                        if !additional.isEmpty && modifiers.isSuperset(of: additional) { rows[rows.count - 1] = item }
                    }
                } else {
                    primary = item.isSeparatorItem ? nil : item
                    if item.isSeparatorItem && rows.last?.isSeparatorItem != false { continue }
                    rows.append(item)
                }
            }
            if rows.last?.isSeparatorItem == true { rows.removeLast() }
            return rows
        }

        private static func identity(_ item: NSMenuItem) -> String {
            let represented =
                item.representedObject.map { String(String(describing: $0).prefix(256)).debugDescription } ?? "nil"
            let attributed = item.attributedTitle?.string.debugDescription ?? "nil"
            let submenu = item.submenu?.title.debugDescription ?? "nil"
            let delegate = item.submenu?.delegate.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let identifiers =
                "identifier=\(item.identifier?.rawValue.debugDescription ?? "nil") submenuIdentifier=\(item.submenu?.identifier?.rawValue.debugDescription ?? "nil")"
            let owner =
                item.identifier?.rawValue == ViewerMainMenu.shareIdentifier
                ? " owner=\(ViewerMainMenu.shareIdentifier)" : ""
            return
                "class=\(NSStringFromClass(type(of: item))) attributedTitle=\(attributed) submenuTitle=\(submenu) submenuDelegate=\(delegate) representedObject=\(represented) \(identifiers)\(owner)"
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

            init(_ item: NSMenuItem, includeChildren: Bool) {
                identity = DebugMenuDump.identity(item)
                title = item.title
                key = item.keyEquivalent
                modifiers = item.keyEquivalentModifierMask
                action = item.action
                enabled = item.isEnabled
                hidden = item.isHiddenOrHasHiddenAncestor
                separator = item.isSeparatorItem
                children = includeChildren ? item.submenu?.items.map(Row.init) ?? [] : []
            }
            init(_ item: NSMenuItem) { self.init(item, includeChildren: true) }

            func line(indent: String) -> String {
                let mask = modifiers
                let symbols = [
                    (NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
                    (.function, "fn"),
                ]
                .filter { mask.contains($0.0) }.map(\.1).joined()
                let marker = hidden ? "[hidden] " : ""
                let label = separator ? "---" : title.debugDescription
                let selector = action.map(NSStringFromSelector) ?? "nil"
                return
                    "\(indent)\(marker)\(label) key=\(key.debugDescription) modifiers=\(symbols)(\(mask.rawValue)) action=\(selector) enabled=\(enabled) \(identity)"
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
                let first = timedSamples + describe("First visible document window")
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
                    to: url,
                    sourceURLs: NSDocumentController.shared.documents.compactMap(\.fileURL)
                        + DocumentWindows.shared.openModels.flatMap(\.sourceURLs))
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
                "appActive=\(NSApp.isActive) keyWindow=\(key?.windowNumber ?? 0) mainWindow=\(mainWindow?.windowNumber ?? 0) snapshotVersion=\(state.version) trackingDepth=\(ShortcutDispatcher.shared.trackingDepth) allowsAutomaticShareMenu=\(NSDocumentController.shared.allowsAutomaticShareMenu)"
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
                    "\(operation.rawValue) AppKit.snapshotEnabled=\(state.content.enabled.contains(operation)) keyDocumentEnabled=\(live)"
                )
            }
            return lines
        }

        private static func describe(_ stage: String) -> String {
            let process = ProcessInfo.processInfo
            var lines =
                [
                    stage,
                    "macOS=\(process.operatingSystemVersionString) pid=\(process.processIdentifier) lifecycle=AppKit",
                ] + printState()
            func append(_ rows: [Row], indent: String) {
                for item in rows {
                    lines.append(item.line(indent: indent))
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
