import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct ShortcutMenuBaselineTests {
    static func waitForMenu(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    /// A posted begin alone cannot put AppKit in tracking mode. Drive a real modal-mode turn without showing a menu.
    static func trackingTurn(_ action: @escaping @MainActor () -> Void = {}) {
        var ran = false
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
                ran = true
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        let deadline = Date(timeIntervalSinceNow: 1)
        while !ran, Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
        }
        #expect(ran)
    }

    // Captured from DocumentCommands before the menu bridge: independent of ShortcutDefaults.
    static let documentKeys: [(String, String, NSEvent.ModifierFlags)] = [
        ("Open from Clipboard", "n", .command),
        ("Print…", "p", .command), ("Print with System Dialog…", "p", [.option, .command]),
        ("PDF of the Sheets…", "e", [.shift, .command]),
        ("Find…", "f", .command), ("Find Next", "g", .command),
        ("Find Previous", "g", [.shift, .command]),
        ("Show as Paper", "p", [.control, .command]),
        ("Single Page", "1", [.option, .command]), ("Spread", "2", [.option, .command]),
        ("Go to Page…", "g", [.option, .command]),
        ("Back", "[", .command), ("Forward", "]", .command),
        ("Increase Text Size", "+", [.option, .command]),
        ("Decrease Text Size", "-", [.option, .command]), ("Original Text Size", "0", [.option, .command]),
        ("Zoom In", "+", .command), ("Zoom Out", "-", .command), ("Fit to Window", "0", .command),
        ("Always Show Toolbar", "t", [.option, .command]), ("Reload", "r", .command),
    ]

    static let listKeys: [(String, String, NSEvent.ModifierFlags)] = [
        ("Show List", "s", [.control, .command]),
        ("Move Image Up", "\u{F700}", [.option, .command]),
        ("Move Document Up", "\u{F700}", [.option, .command]),
        ("Move Image Down", "\u{F701}", [.option, .command]),
        ("Move Document Down", "\u{F701}", [.option, .command]),
    ]

    /// Pin all bindings, including the absence of a key on the other rows, independently of ShortcutDefaults.
    static func checkDescriptorKeys(_ rows: [DocumentMenuDescriptor]) throws {
        let layoutKeys: [ShortcutOperationID: String] = [
            .printLayoutSingle: "1", .printLayoutDuplex: "2", .printLayoutBookletLarge: "3",
            .printLayoutBookletSmall: "4", .printLayoutTwoUpLarge: "5", .printLayoutHandout: "6",
        ]
        let bindings = documentKeys + listKeys + [("Reopen Closed Clipboard Document", "t", [.shift, .command])]
        let keys = Dictionary(uniqueKeysWithValues: bindings.map { ($0.0, ($0.1, $0.2)) })
        var seen: Set<String> = []
        for row in rows {
            let expected: (String, NSEvent.ModifierFlags)?
            if let operation = row.operation, let key = layoutKeys[operation] {
                expected = (key, .command)
            } else if case .key(let title) = row.title {
                let key = title == "Print" ? "Print…" : title == "Show as Web" ? "Show as Paper" : title
                seen.insert(key)
                expected = keys[key]
            } else {
                expected = nil
            }
            let actual = row.shortcut
            if let (key, flags) = expected {
                let shortcut = try #require(actual, "Missing binding: \(row.id)")
                #expect(String(shortcut.key.character) == key, "\(row.id)")
                var modifiers: EventModifiers = []
                if flags.contains(.command) { modifiers.insert(.command) }
                if flags.contains(.control) { modifiers.insert(.control) }
                if flags.contains(.option) { modifiers.insert(.option) }
                if flags.contains(.shift) { modifiers.insert(.shift) }
                #expect(shortcut.modifiers == modifiers, "\(row.id)")
            } else {
                #expect(actual == nil, "Unexpected binding: \(row.id)")
            }
        }
        #expect(Set(documentKeys.map { $0.0 }).isSubset(of: seen))
    }

    static func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { Self.items($0) } ?? []) }
    }

    @Test("書き出すサブメニューは読むPDFと用紙PDFとPNGとHTMLとPDFの共有をこの順に持つ")
    func exportMenu() throws {
        func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
        let menu = try #require(NSApp.mainMenu)
        let file = try #require(menu.item(at: 1)?.submenu)
        let exports = try #require(file.items.first { $0.title == localized("Export") }?.submenu)
        #expect(
            exports.items.filter { !$0.isSeparatorItem }.map(\.title) == [
                localized("PDF for Reading…"), localized("PDF of the Sheets…"), localized("Images (PNG)…"),
                localized("HTML…"), localized("Share PDF…"),
            ])
        // The system's own Share item hands over the opened file; a second item of that name would be ambiguous.
        #expect(!file.items.contains { $0.title == localized("Share PDF…") })
        #expect(exports.items[0].keyEquivalent.isEmpty)
        #expect(exports.items[1].keyEquivalent == "e")
        #expect(exports.items[1].keyEquivalentModifierMask == [.shift, .command])
    }

    @Test("起動時の実メニューは印刷項目と八つのレイアウトをブリッジに一度だけ結び付ける")
    func nativePrintTargets() throws {
        let bridge = ShortcutDispatcher.shared.bridge
        let items = Self.items(try #require(NSApp.mainMenu))
        let before = items.map { ShortcutMenuKey(item: $0) }
        bridge.reconcile()
        for operation in [ShortcutOperationID.documentPrint, .documentPrintSystem, .documentExportPDF, .printSettings]
            + ShortcutPrintLayouts.operations
        {
            let item = try #require(bridge.items[operation], "Unmanaged menu operation: \(operation)")
            #expect(items.contains { $0 === item })
            #expect(item.target === bridge)
            #expect(item.identifier == ShortcutMenuBridge.identifier(operation))
        }
        for (item, expected) in zip(items, before) {
            #expect(item.keyEquivalent == expected.key)
            #expect(item.keyEquivalentModifierMask == expected.modifiers)
        }
    }

    @Test("既定の全メニューバーは従来のキーを保持し標準の開くと設定を一つずつ残す")
    func defaultMenuKeys() throws {
        let menu = try #require(NSApp.mainMenu)
        let all = Self.items(menu)
        func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
        let file = try #require(menu.item(at: 1)?.submenu)
        #expect(file.items.filter { $0.title == localized("Open from URL…") }.count == 1)
        for (title, key, modifiers) in Self.documentKeys {
            let variants =
                title == "Print…"
                ? ["Print…", "Print"]
                : title == "Show as Paper" ? ["Show as Paper", "Show as Web"] : [title]
            let matches = all.filter { variants.map { localized($0) }.contains($0.title) }
            let item = try #require(matches.count == 1 ? matches.first : nil, "\(title)")
            #expect(item.keyEquivalent == key, "\(title)")
            #expect(item.keyEquivalentModifierMask == modifiers, "\(title)")
        }
        for title in [
            "Streaming Preview", "Save as File…", "View Options…", "Select Text", "Float on Top",
            "Show as Slides", "Getting Started with Surimono", "Keys and Gestures", "Check for Updates…",
            "Open as Binder", "Add Documents…", "Reset Document Settings", "Choose Style…", "Print Settings…",
            "Save Current Settings…", "Manage Setting Sets…", "Sort by Name", "Start Each Document on an Odd Page",
            "Remove from List", "Bookmark This Page", "Next Bookmark", "Previous Bookmark",
            "PDF for Reading…", "Images (PNG)…", "HTML…", "Share PDF…", "Copy as HTML", "Copy as Rich Text",
        ] {
            for item in all where item.title == localized(title) {
                #expect(item.keyEquivalent.isEmpty, "Unexpected default key: \(title)")
            }
        }
        let view = try #require(menu.item(at: 3)?.submenu)
        let pin = try #require(view.items.firstIndex { $0.title == localized("Float on Top") })
        let spaces = try #require(view.items.dropFirst(pin + 1).first)
        #expect(spaces.title == localized("Show on All Spaces"))
        #expect(spaces.keyEquivalent.isEmpty)
        let edit = try #require(menu.item(at: 2)?.submenu)
        let copyIndex = try #require(edit.items.firstIndex { $0.title == localized("Copy as HTML") })
        #expect(edit.items.dropFirst(copyIndex + 1).first?.title == localized("Copy as Rich Text"))
        let opens = all.filter {
            $0.action == NSSelectorFromString("openDocument:")
                || $0.identifier?.rawValue == "surimono.shortcut.app.open"
        }
        #expect(opens.count == 1)
        #expect(opens.first?.keyEquivalent == "o")
        let appMenu = try #require(menu.items.first?.submenu)
        let settings = appMenu.items.filter { $0.keyEquivalent == "," }
        #expect(settings.count == 1)
        #expect(settings.first?.keyEquivalentModifierMask == .command)
        // Platform commands are pinned by selector, independently of the machine's menu language.
        let platform: [String: (String, NSEvent.ModifierFlags)] = [
            "openDocument:": ("o", .command), "terminate:": ("q", .command),
            "hide:": ("h", .command), "hideOtherApplications:": ("h", [.option, .command]),
            "performClose:": ("w", .command), "performMiniaturize:": ("m", .command),
            "toggleFullScreen:": ("f", [.control, .command]),
            "undo:": ("z", .command), "redo:": ("Z", [.shift, .command]),
            "cut:": ("x", .command), "copy:": ("c", .command), "paste:": ("v", .command),
            "selectAll:": ("a", .command), "pasteAsPlainText:": ("v", [.option, .shift, .command]),
        ]
        for item in all {
            if let action = item.action, DocumentEditMenu.hiddenActions.contains(action) {
                #expect(item.isHidden && !item.allowsKeyEquivalentWhenHidden)
            }
            if let action = item.action, let (key, flags) = platform[NSStringFromSelector(action)] {
                #expect(item.keyEquivalent.lowercased() == key.lowercased())
                let impliedShift: NSEvent.ModifierFlags =
                    item.keyEquivalent != item.keyEquivalent.lowercased() ? .shift : []
                // Once AppKit has populated the menus (it does so on its own, for example for menu search), it
                // shows its own variants of two commands: Full Screen with the Globe key, and the Option alternate
                // of a command beside the plain one. Both are AppKit's, not a changed default.
                let name = NSStringFromSelector(action)
                var accepted = [flags]
                if name == "toggleFullScreen:" { accepted.append(.function) }
                if item.isAlternate { accepted.append(flags.union(.option)) }
                #expect(
                    accepted.contains(item.keyEquivalentModifierMask.union(impliedShift)),
                    "\(name), alternate: \(item.isAlternate), mask: \(item.keyEquivalentModifierMask.rawValue)")
            }
        }
        let document = try #require(menu.items.first { $0.title == localized("Document") }?.submenu)
        let layouts = try #require(document.items.first?.submenu).items.filter { !$0.isSeparatorItem }
        #expect(layouts.prefix(6).map(\.keyEquivalent) == ["1", "2", "3", "4", "5", "6"])
        #expect(layouts.prefix(6).allSatisfy { $0.keyEquivalentModifierMask == .command })
        #expect(layouts.dropFirst(6).allSatisfy { $0.keyEquivalent.isEmpty })
        for (title, key, flags) in Self.listKeys {
            for item in all where item.title == localized(title) {
                if !item.isHidden {
                    #expect(item.keyEquivalent == key)
                    #expect(item.keyEquivalentModifierMask == flags)
                }
            }
        }
    }
}
