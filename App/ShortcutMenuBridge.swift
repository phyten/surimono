import AppKit
import SurimonoCore

@MainActor
final class ShortcutMenuBridge: NSObject {
    struct Entry {
        let operation: ShortcutOperationID
        let menu: Int
        let parents: [String]
        let titles: [String]
        init(_ operation: ShortcutOperationID, _ menu: Int, _ titles: [String], parents: [String] = []) {
            self.operation = operation
            self.menu = menu
            self.titles = titles
            self.parents = parents
        }
    }

    static let entries: [Entry] =
        [
            .init(.appOpen, 1, []), .init(.appSettings, 0, []),
            .init(.appOpenURL, 1, ["Open from URL…"]),
            .init(.clipboardReopen, 1, ["Reopen Closed Clipboard Document"]),
            .init(.clipboardOpen, 1, ["Open from Clipboard"]),
            .init(.clipboardOpenPrintScreen, 1, ["Open Clipboard on the Print Screen"]),
            .init(.documentPrint, 1, ["Print…", "Print"]),
            .init(.documentPrintSystem, 1, ["Print with System Dialog…"]),
            .init(.documentExportPDF, 1, ["PDF of the Sheets…"], parents: ["Export"]),
            .init(.documentExportReadingPDF, 1, ["PDF for Reading…"], parents: ["Export"]),
            .init(.documentExportPNG, 1, ["Images (PNG)…"], parents: ["Export"]),
            .init(.documentExportHTML, 1, ["HTML…"], parents: ["Export"]),
            .init(.documentCopyHTML, 2, ["Copy as HTML"]),
            .init(.documentCopyRichText, 2, ["Copy as Rich Text"]),
            .init(.documentShare, 1, ["Share PDF…"], parents: ["Export"]),
            .init(.printSettings, 4, ["Print Settings…"]),
            .init(.appStreamingPreview, 1, ["Streaming Preview"]),
            .init(.documentSaveAsFile, 1, ["Save as File…"]),
            .init(.documentFind, 2, ["Find…"]), .init(.documentFindNext, 2, ["Find Next"]),
            .init(.documentFindPrevious, 2, ["Find Previous"]),
            .init(.viewHtmlPresentation, 3, ["Show as Web", "Show as Paper"]),
            .init(.viewIgnoreSlides, 3, ["Show as Slides"]),
            .init(.viewSingle, 3, ["Single Page"]), .init(.viewSpread, 3, ["Spread"]),
            .init(.documentGoToPage, 3, ["Go to Page…"]),
            .init(.readingBack, 3, ["Back"]),
            .init(.readingForward, 3, ["Forward"]),
            .init(.bookmarkToggle, 3, ["Bookmark This Page"]),
            .init(.bookmarkNext, 3, ["Next Bookmark"]),
            .init(.bookmarkPrevious, 3, ["Previous Bookmark"]),
            .init(.textIncrease, 3, ["Increase Text Size"]),
            .init(.textDecrease, 3, ["Decrease Text Size"]), .init(.textReset, 3, ["Original Text Size"]),
            .init(.viewZoomIn, 3, ["Zoom In"]),
            .init(.viewZoomOut, 3, ["Zoom Out"]), .init(.viewZoomFit, 3, ["Fit to Window"]),
            .init(.viewToolbarAlways, 3, ["Always Show Toolbar"]), .init(.viewFloatOnTop, 3, ["Float on Top"]),
            .init(.viewShowOnAllSpaces, 3, ["Show on All Spaces"]),
            .init(.appGettingStarted, 6, ["Getting Started with Surimono"]),
            .init(.appKeyGuide, 6, ["Keys and Gestures"]), .init(.appCheckUpdates, 0, ["Check for Updates…"]),
            .init(.documentOpenBinder, 4, ["Open as Binder"]), .init(.documentAdd, 4, ["Add Documents…"]),
            .init(.styleChoose, 4, ["Choose Style…"]),
            .init(.documentResetSettings, 4, ["Reset Document Settings"]), .init(.documentReload, 4, ["Reload"]),
            .init(.settingSetSave, 4, ["Save Current Settings…"], parents: ["Setting Sets"]),
            .init(.settingSetManage, 4, ["Manage Setting Sets…"], parents: ["Setting Sets"]),
            .init(.listToggle, 4, ["Show List"], parents: ["Binder", "Images"]),
            .init(.listMoveUp, 4, ["Move Document Up", "Move Image Up"], parents: ["Binder", "Images"]),
            .init(.listMoveDown, 4, ["Move Document Down", "Move Image Down"], parents: ["Binder", "Images"]),
            .init(.listSortByName, 4, ["Sort by Name"], parents: ["Binder", "Images"]),
            .init(.binderOddPageStarts, 4, ["Start Each Document on an Odd Page"], parents: ["Binder", "Images"]),
        ]
        + ShortcutPrintLayouts.operations.map { Entry($0, 4, [], parents: ["Print Layout"]) }
    static let operations = Set(entries.map(\.operation))
    static func identifier(_ operation: ShortcutOperationID) -> NSUserInterfaceItemIdentifier {
        .init("surimono.shortcut." + operation.rawValue)
    }

    private let controller: ShortcutController
    private let menu: () -> NSMenu?
    private let keyWindow: () -> NSWindow?
    private let lifecycleNotifications: NotificationCenter
    private var reconciliationPending = false
    private weak var reconciledMenu: NSMenu?
    private let model: () -> DocumentViewModel?
    private let localize: (String) -> String
    private let externalKey: (NSMenuItem) -> String
    var dispatch: (ShortcutOperationID) -> Void = { _ in }
    private(set) var items: [ShortcutOperationID: NSMenuItem] = [:]
    private(set) var ambiguous: Set<ShortcutOperationID> = []
    private var originals: [ShortcutOperationID: (NSMenuItem, AnyObject?, Selector?)] = [:]
    private var reconciling = false
    private var started = false

    init(
        controller: ShortcutController, menu: @escaping () -> NSMenu? = { NSApp.mainMenu },
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        model: (() -> DocumentViewModel?)? = nil,
        lifecycleNotifications: NotificationCenter = .default,
        localize: @escaping (String) -> String = { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) },
        externalKey: @escaping (NSMenuItem) -> String = { $0.userKeyEquivalent }
    ) {
        self.controller = controller
        self.menu = menu
        self.keyWindow = keyWindow
        self.model = model ?? { DocumentWindows.shared.model(for: keyWindow()) }
        self.lifecycleNotifications = lifecycleNotifications
        self.localize = localize
        self.externalKey = externalKey
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [
            NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification,
            NSMenu.didBeginTrackingNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: ClosedClipboardDocuments.didChange,
            object: ClipboardWindows.shared.preferences)
        for name in [
            NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didUpdateNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        ] {
            lifecycleNotifications.addObserver(self, selector: #selector(changed), name: name, object: nil)
        }
        reconcile()
        reconcileAfterMenuAssembly()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        lifecycleNotifications.removeObserver(self)
        started = false
        for (_, (item, target, action)) in originals where item.target === self {
            item.target = target
            item.action = action
        }
        originals = [:]
    }

    @objc private func changed(_ notification: Notification) {
        // A fully assembled menu can replace mainMenu without another item notification. Application updates
        // catch that installation even when no window becomes key and no menu is opened.
        if notification.name == NSApplication.didUpdateNotification, menu() === reconciledMenu { return }
        if let changedMenu = notification.object as? NSMenu {
            var root = changedMenu
            while let parent = root.supermenu { root = parent }
            guard root === menu() else { return }
            // AppKit posts item changes while it holds its key-equivalent lock, for example while it fills the
            // Services menu. Writing a key equivalent from inside that notification takes the same lock again and
            // deadlocks the main thread, so item changes are reconciled after the notification has returned. Key
            // events reconcile first on their own, so no stale key can fire in between.
            if notification.name != NSMenu.didBeginTrackingNotification {
                reconcileAfterMenuAssembly()
                return
            }
        }
        reconcile()
    }

    private func reconcileAfterMenuAssembly() {
        guard started, !reconciliationPending else { return }
        reconciliationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reconciliationPending = false
            if started { reconcile() }
        }
    }

    func reconcile() {
        guard !reconciling, let root = menu() else { return }
        reconciledMenu = root
        reconciling = true
        defer { reconciling = false }
        DocumentEditMenu.hideItems(in: root)
        var found: [ShortcutOperationID: NSMenuItem] = [:]
        var external: [ShortcutOperationID: ShortcutCombination] = [:]
        let history = ClipboardWindows.shared.preferences?.closedClipboardDocuments.entries.map(\.menuItem) ?? []
        ambiguous = []
        for entry in Self.entries {
            guard root.items.indices.contains(entry.menu), var parent = root.items[entry.menu].submenu else { continue }
            if !entry.parents.isEmpty {
                let parents = parent.items.filter { entry.parents.map(localize).contains($0.title) }
                guard parents.count == 1, let submenu = parents.first?.submenu else { continue }
                parent = submenu
            }
            // The layout submenu has eight fixed semantic slots, with localized, series-dependent titles.
            // Require the full shape before assigning identities; titles and layout IDs are never persisted as keys.
            let layouts = parent.items.filter { !$0.isSeparatorItem }
            let layoutIndex = ShortcutPrintLayouts.operations.firstIndex(of: entry.operation)
            let matches = parent.items.filter { item in
                if let layoutIndex {
                    return layouts.count == 8 && layouts[layoutIndex] === item
                }
                if item.identifier == Self.identifier(entry.operation) { return true }
                if entry.operation == .appOpen { return item.action == NSSelectorFromString("openDocument:") }
                if entry.operation == .appSettings {
                    return ["showSettingsWindow:", "showPreferencesWindow:"].contains(
                        item.action.map(NSStringFromSelector) ?? "")
                        || item.keyEquivalent == "," || item.title == localize("Settings") + "…"
                }
                return entry.titles.map(localize).contains(item.title)
            }
            guard matches.count == 1, let item = matches.first else {
                if matches.count > 1 { ambiguous.insert(entry.operation) }
                continue
            }
            if let action = item.action, DocumentEditMenu.hiddenActions.contains(action) { continue }
            item.identifier = Self.identifier(entry.operation)
            found[entry.operation] = item
            if item.target !== self { originals[entry.operation] = (item, item.target, item.action) }
            if entry.operation != .appOpen && entry.operation != .appSettings {
                if item.target !== self { item.target = self }
                if item.action != #selector(invoke(_:)) { item.action = #selector(invoke(_:)) }
                // SwiftUI's validation is lazy. Resolve availability against the key window on invocation.
                if !item.isEnabled { item.isEnabled = true }
            }
            item.allowsKeyEquivalentWhenHidden = false
            let desired =
                entry.operation == .clipboardReopen && history.isEmpty
                ? nil : controller.snapshot.keys(for: entry.operation).first
            item.allowsAutomaticKeyEquivalentLocalization = controller.snapshot.overrides[entry.operation] == nil
            item.allowsAutomaticKeyEquivalentMirroring = controller.snapshot.overrides[entry.operation] == nil
            let value = desired.flatMap(ShortcutMenuKey.init)
            if item.keyEquivalent != (value?.key ?? "") { item.keyEquivalent = value?.key ?? "" }
            let flags = value?.modifiers ?? .command
            if item.keyEquivalentModifierMask != flags { item.keyEquivalentModifierMask = flags }
        }
        items = found
        let current = model()
        for operation in ShortcutPrintLayouts.operations {
            if let item = items[operation],
                let layout = ShortcutPrintLayouts.layout(for: operation, series: current?.trayPaperSeries ?? .a)
            {
                let title = layout.displayName(
                    language: current?.language ?? Bundle.main.preferredLocalizations.first ?? "en")
                if item.title != title { item.title = title }
            }
        }
        let titles: [ShortcutOperationID: String] = [
            .documentPrint: current?.mode == .print ? "Print" : "Print…",
            .viewHtmlPresentation: current?.htmlPresentation == .paper ? "Show as Web" : "Show as Paper",
            .listMoveUp: current?.binder == nil ? "Move Image Up" : "Move Document Up",
            .listMoveDown: current?.binder == nil ? "Move Image Down" : "Move Document Down",
        ]
        for (operation, title) in titles {
            if let item = items[operation], item.title != localize(title) { item.title = localize(title) }
        }
        let states: [ShortcutOperationID: Bool] = [
            .bookmarkToggle: current?.isVisiblePageBookmarked ?? false,
            .viewIgnoreSlides: current?.slideDeck != nil,
            .viewToolbarAlways: current?.isBandAlwaysVisible ?? false,
            .viewFloatOnTop: current?.isAlwaysOnTop ?? false,
            .viewShowOnAllSpaces: current?.showsOnAllSpaces ?? false,
            .listToggle: current?.isDrawerOpen ?? false,
            .binderOddPageStarts: current?.binderStartsOnFront ?? false,
        ]
        for (operation, checked) in states {
            let state: NSControl.StateValue = checked ? .on : .off
            if let item = items[operation], item.state != state { item.state = state }
        }
        items[.clipboardReopen]?.isHidden = history.isEmpty
        if let parent = items[.clipboardReopen]?.menu?.item(withTitle: localize("Recently Closed Clipboard Documents"))
        {
            updateHistoryMenu(parent, history)
        }
        items[.documentSaveAsFile]?.isHidden = current?.canSaveAsFile != true
        items[.documentOpenBinder]?.isHidden = current?.includePlan == nil
        if let parent = items[.listToggle]?.menu {
            for item in parent.items where item.title == localize("Remove from List") {
                item.isHidden = current?.binder == nil
                item.allowsKeyEquivalentWhenHidden = false
            }
        }
        if let list = items[.listToggle]?.menu {
            let absent = current?.binder == nil && current?.imageBundle == nil
            list.supermenu?.items.first { $0.submenu === list }?.isHidden = absent
            for operation in [ShortcutOperationID.listToggle, .listMoveUp, .listMoveDown, .listSortByName] {
                items[operation]?.isHidden = absent
            }
            items[.binderOddPageStarts]?.isHidden = current?.binder == nil
        }
        for (operation, item) in items {
            if !externalKey(item).isEmpty, let actual = ShortcutMenuKey(item: item).combination {
                external[operation] = actual
            }
        }
        if controller.menuAmbiguities != ambiguous { controller.menuAmbiguities = ambiguous }
        controller.setExternalMenuKeys(external)
        for (operation, item) in items where external[operation] == nil {
            let candidate = controller.localKeys(for: operation).first
            let protectsInput =
                ShortcutDispatcher.isTextInput(keyWindow()?.firstResponder)
                && candidate?.modifiers.contains(.command) == false
            let surfaceOnly =
                ShortcutOperation.operation(operation).allowsBareKeys
                && candidate?.modifiers.intersection([.command, .control]).isEmpty == true
            let key = item.isHidden || protectsInput || surfaceOnly ? nil : candidate.flatMap(ShortcutMenuKey.init)
            if item.keyEquivalent != (key?.key ?? "") { item.keyEquivalent = key?.key ?? "" }
            if item.keyEquivalentModifierMask != (key?.modifiers ?? .command) {
                item.keyEquivalentModifierMask = key?.modifiers ?? .command
            }
        }
    }

    private func updateHistoryMenu(_ parent: NSMenuItem, _ history: [ClosedClipboardDocuments.MenuItem]) {
        let submenu = parent.submenu ?? NSMenu(title: parent.title)
        if parent.submenu == nil { parent.submenu = submenu }
        parent.isHidden = history.isEmpty
        if !submenu.items.elementsEqual(
            history, by: { $0.representedObject as? ContentHash == $1.id && $0.title == $1.title })
        {
            submenu.removeAllItems()
            for entry in history {
                let item = submenu.addItem(
                    withTitle: entry.title, action: #selector(reopenClosed(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
            }
        }
    }

    @objc private func reopenClosed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ContentHash else { return }
        ClipboardWindows.shared.reopenClosed(id)
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        reconcile()
        guard let operation = items.first(where: { $0.value === sender })?.key else { return }
        dispatch(operation)
    }

    func invokeStandard(_ operation: ShortcutOperationID) {
        guard let (item, target, action) = originals[operation], let action else { return }
        NSApp.sendAction(action, to: target, from: item)
    }
}

struct ShortcutMenuKey {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ combination: ShortcutCombination) {
        guard let value = Self.character(combination.key) else { return nil }
        key = value
        modifiers = combination.modifiers.appKit
    }

    init(item: NSMenuItem) {
        key = item.keyEquivalent
        modifiers = item.keyEquivalentModifierMask
    }

    var combination: ShortcutCombination? {
        guard !key.isEmpty else { return nil }
        let named = Self.named(key)
        var flags = ShortcutModifiers(modifiers)
        if key != key.lowercased() { flags.insert(.shift) }
        return try? ShortcutCombination(
            key: named.map(ShortcutKey.named) ?? .character(key), modifiers: flags
        )
        .normalized()
    }

    static func named(_ character: String) -> ShortcutNamedKey? {
        // AppKit menus and NSEvent use the backspace and delete characters for the same backward-delete key.
        if character == "\u{7F}" { return .deleteBackward }
        return ShortcutNamedKey.allCases.first { Self.character(.named($0)) == character }
    }

    static func character(_ key: ShortcutKey) -> String? {
        switch key {
        case .character(let value): return value
        case .macVirtualKey: return nil
        case .named(let name):
            let values: [ShortcutNamedKey: UInt32] = [
                .upArrow: 0xF700, .downArrow: 0xF701, .leftArrow: 0xF702, .rightArrow: 0xF703,
                .space: 32, .deleteBackward: 8, .deleteForward: 0xF728, .escape: 27, .tab: 9,
                .return: 13, .enter: 3, .home: 0xF729, .end: 0xF72B, .pageUp: 0xF72C, .pageDown: 0xF72D,
            ]
            if let scalar = values[name].flatMap(UnicodeScalar.init) { return String(scalar) }
            if name.rawValue.first == "f", let number = UInt32(name.rawValue.dropFirst()),
                let scalar = UnicodeScalar(0xF703 + number)
            {
                return String(scalar)
            }
            return nil
        }
    }
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        for (appKit, value): (NSEvent.ModifierFlags, Self) in [
            (.command, .command), (.control, .control), (.option, .option), (.shift, .shift),
        ] where flags.contains(appKit) { insert(value) }
    }

    var appKit: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        for (value, flag): (Self, NSEvent.ModifierFlags) in [
            (.command, .command), (.control, .control), (.option, .option), (.shift, .shift),
        ] where contains(value) { result.insert(flag) }
        return result
    }
}
