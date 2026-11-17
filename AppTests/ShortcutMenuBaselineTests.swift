import AppKit
import Testing

@testable import Surimono

@MainActor
struct ShortcutMenuBaselineTests {
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

    static func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
    }

    @Test("書き出すサブメニューは読むPDFと用紙PDFとPNGとHTMLをこの順に持つ")
    func exportMenu() throws {
        func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
        let menu = try #require(NSApp.mainMenu)
        let file = try #require(menu.item(at: 1)?.submenu)
        let exports = try #require(file.items.first { $0.title == localized("Export") }?.submenu)
        #expect(
            exports.items.map(\.title) == [
                localized("PDF for Reading…"), localized("PDF of the Sheets…"), localized("Images (PNG)…"),
                localized("HTML…"),
            ])
        #expect(exports.items[0].keyEquivalent.isEmpty)
        #expect(exports.items[1].keyEquivalent == "e")
        #expect(exports.items[1].keyEquivalentModifierMask == [.shift, .command])
    }

    @Test("既定の全メニューバーは従来のキーを保持し標準の開くと設定を一つずつ残す")
    func defaultMenuKeys() throws {
        let menu = try #require(NSApp.mainMenu)
        let all = Self.items(menu)
        func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
        for (title, key, modifiers) in Self.documentKeys {
            let variants =
                title == "Print…"
                ? ["Print…", "Print"]
                : title == "Show as Paper" ? ["Show as Paper", "Show as Web"] : [title]
            let matches = all.filter { variants.map(localized).contains($0.title) }
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
            "PDF for Reading…", "Images (PNG)…", "HTML…", "Share…", "Copy as Rich Text", "Copy as HTML",
        ] {
            for item in all where item.title == localized(title) {
                #expect(item.keyEquivalent.isEmpty, "Unexpected default key: \(title)")
            }
        }
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
        let listKeys: [(String, String, NSEvent.ModifierFlags)] = [
            ("Show List", "s", [.control, .command]),
            ("Move Image Up", "\u{F700}", [.option, .command]),
            ("Move Document Up", "\u{F700}", [.option, .command]),
            ("Move Image Down", "\u{F701}", [.option, .command]),
            ("Move Document Down", "\u{F701}", [.option, .command]),
        ]
        for (title, key, flags) in listKeys {
            for item in all where item.title == localized(title) {
                if !item.isHidden {
                    #expect(item.keyEquivalent == key)
                    #expect(item.keyEquivalentModifierMask == flags)
                }
            }
        }
    }
}
