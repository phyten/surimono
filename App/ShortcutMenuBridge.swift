import AppKit
import SurimonoCore

@MainActor
final class ShortcutMenuBridge: NSObject, NSMenuItemValidation {
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
            .init(.viewOptions, 3, ["View Options…"]), .init(.viewSelectText, 3, ["Select Text"]),
            .init(.listRemove, 4, ["Remove from List"], parents: ["Binder"]),
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
    // These clicks use the original SwiftUI action. Their customizable keys belong to a focused surface.
    private static let clickOnly: Set<ShortcutOperationID> = [.viewOptions, .viewSelectText, .listRemove]
    static let operations = Set(entries.map(\.operation)).subtracting(clickOnly)
    static func identifier(_ operation: ShortcutOperationID) -> NSUserInterfaceItemIdentifier {
        .init("surimono.shortcut." + operation.rawValue)
    }

    // SwiftUI can still have the previous series on screen while assembling the new tree.
    // All supported layout names are fixed for the application's launch language.
    private static let layoutTitles = Dictionary(
        uniqueKeysWithValues: ShortcutPrintLayouts.operations.map { operation in
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            let titles = PaperSeries.allCases.compactMap { series in
                ShortcutPrintLayouts.layout(for: operation, series: series)?.displayName(language: language)
            }
            return (operation, Set(titles))
        })

    private let controller: ShortcutController
    private let menu: () -> NSMenu?
    private let keyWindow: () -> NSWindow?
    private let lifecycleNotifications: NotificationCenter
    let menuState: MenuState
    private(set) lazy var writes = MenuWrites("bridge", canWrite: { [weak self] in self?.updates.allowsWrites == true })
    private let preferences: () -> AppPreferences?
    private(set) lazy var updates = MenuUpdates(
        state: menuState, root: menu, model: model, preferences: preferences, lifecycle: lifecycleNotifications
    ) { [weak self] root in self?.apply(in: root) }
    var canDispatch: ((ShortcutOperationID) -> Bool)?
    private let model: () -> DocumentViewModel?
    private let localize: (String) -> String
    private let externalKey: (NSMenuItem) -> String
    var dispatch: (ShortcutOperationID) -> Void = { _ in }
    private(set) var items: [ShortcutOperationID: NSMenuItem] = [:]
    private(set) var ambiguous: Set<ShortcutOperationID> = []
    private var originals: [ShortcutOperationID: (NSMenuItem, AnyObject?, Selector?)] = [:]
    private(set) var reconcilePasses = 0

    init(
        controller: ShortcutController, menu: @escaping () -> NSMenu? = { NSApp.mainMenu },
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        model: (() -> DocumentViewModel?)? = nil,
        lifecycleNotifications: NotificationCenter = .default, menuState: MenuState = MenuState(),
        preferences: @escaping () -> AppPreferences? = { AppPreferences.shared },
        localize: @escaping (String) -> String = { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) },
        externalKey: @escaping (NSMenuItem) -> String = { $0.userKeyEquivalent }
    ) {
        self.menuState = menuState
        self.preferences = preferences
        self.controller = controller
        self.menu = menu
        self.keyWindow = keyWindow
        self.model = model ?? { DocumentWindows.shared.model(for: keyWindow()) }
        self.lifecycleNotifications = lifecycleNotifications
        self.localize = localize
        self.externalKey = externalKey
    }

    func start() { updates.start() }

    func stop() {
        updates.stop { [weak self] in self?.restoreTargets() }
    }

    private func restoreTargets() {
        guard !MenuTrace.noBridgeWrites else { return }
        for (_, (item, target, action)) in originals where item.target === self {
            // Keeping our target until the last write lets restoration resume if tracking interrupts it.
            writes.set(item, \.action, "action", action)
            setTarget(target, item: item)
        }
        if updates.allowsWrites { originals.removeAll() }
    }

    func reconcile() { updates.reconcile() }

    private func setTarget(_ target: AnyObject?, item: NSMenuItem) {
        guard item.target !== target else { return }
        writes.change(
            item, "target", from: item.target.map { String(describing: type(of: $0)) } ?? "nil",
            to: target.map { String(describing: type(of: $0)) } ?? "nil"
        ) {
            item.target = target
        }
    }

    private func matchingItems(_ entry: Entry, in root: NSMenu) -> [NSMenuItem] {
        guard root.items.indices.contains(entry.menu), var parent = root.items[entry.menu].submenu else { return [] }
        if !entry.parents.isEmpty {
            let titles = entry.parents.map(localize)
            let parents = parent.items.filter { titles.contains($0.title) }
            guard parents.count == 1, let submenu = parents.first?.submenu else { return [] }
            parent = submenu
        }
        let identifier = Self.identifier(entry.operation)
        let layouts = Self.layoutTitles[entry.operation]
        let titles = entry.titles.map(localize)
        return parent.items.filter { item in
            // SwiftUI does not promise to propagate View.id to NSMenuItem. Use the AX identity where
            // available, or the unique semantic layout title in this submenu, even during partial assembly.
            if let layouts {
                let ax: String? = item.accessibilityIdentifier()
                if let ax, ax.hasPrefix("surimono.shortcut.") { return ax == identifier.rawValue }
                return layouts.contains(item.title)
            }
            if entry.operation == .appOpen { return item.action == NSSelectorFromString("openDocument:") }
            if entry.operation == .appSettings {
                return item.identifier == identifier
                    || ["showSettingsWindow:", "showPreferencesWindow:"].contains(
                        item.action.map(NSStringFromSelector) ?? "")
                    || item.keyEquivalent == "," || item.title == localize("Settings") + "…"
            }
            guard titles.contains(item.title) else { return false }
            let ax: String? = item.accessibilityIdentifier()
            return ax?.hasPrefix("surimono.shortcut.") != true || ax == identifier.rawValue
        }
    }

    private func apply(in root: NSMenu) {
        guard !MenuTrace.noBridgeWrites else { return }
        reconcilePasses += 1
        var found: [ShortcutOperationID: NSMenuItem] = [:]
        var external: [ShortcutOperationID: ShortcutCombination] = [:]

        ambiguous = []
        for entry in Self.entries {
            let identifier = Self.identifier(entry.operation)
            let matches = matchingItems(entry, in: root)
            guard matches.count == 1, let item = matches.first else {
                if matches.count > 1 { ambiguous.insert(entry.operation) }
                continue
            }
            if let action = item.action, DocumentEditMenu.hiddenActions.contains(action) { continue }
            writes.set(item, \.identifier, "identifier", identifier) { id in
                guard let id,
                    Self.operations.contains(where: { Self.identifier($0) == id })
                        || Self.clickOnly.contains(where: { Self.identifier($0) == id })
                else { return "<other>" }
                return id.rawValue
            }
            found[entry.operation] = item
            if item.target !== self { originals[entry.operation] = (item, item.target, item.action) }
            if entry.operation != .appOpen && entry.operation != .appSettings {
                setTarget(self, item: item)
                writes.set(item, \.action, "action", #selector(invoke(_:)))
            }
            writes.set(
                item, \.allowsKeyEquivalentWhenHidden, "allowsKeyEquivalentWhenHidden", false)
        }
        items = found
        for (operation, item) in items where !Self.clickOnly.contains(operation) {
            if !externalKey(item).isEmpty, let actual = ShortcutMenuKey(item: item).combination {
                external[operation] = actual
            }
        }
        if controller.menuAmbiguities != ambiguous { controller.menuAmbiguities = ambiguous }
        controller.setExternalMenuKeys(external)
        for (operation, item) in items where external[operation] == nil && !Self.clickOnly.contains(operation) {
            let candidate = controller.localKeys(for: operation).first
            let protectsInput =
                ShortcutDispatcher.isTextInput(keyWindow()?.firstResponder)
                && candidate?.modifiers.contains(.command) == false
            let surfaceOnly =
                ShortcutOperation.operation(operation).allowsBareKeys
                && candidate?.modifiers.intersection([.command, .control]).isEmpty == true
            let key = item.isHidden || protectsInput || surfaceOnly ? nil : candidate.flatMap(ShortcutMenuKey.init)
            writes.set(item, \.keyEquivalent, "keyEquivalent", key?.key ?? "")
            writes.set(
                item, \.keyEquivalentModifierMask, "keyEquivalentModifierMask", key?.modifiers ?? .command
            ) { String($0.rawValue) }
        }
    }

    private func currentItem(_ operation: ShortcutOperationID) -> NSMenuItem? {
        // SwiftUI may have replaced the item since the last writable pass. Resolve presence without binding it.
        guard let root = menu(), let entry = Self.entries.first(where: { $0.operation == operation }) else {
            return nil
        }
        let matches = matchingItems(entry, in: root)
        return matches.count == 1 ? matches.first : nil
    }

    func commandIsPresent(_ operation: ShortcutOperationID) -> Bool {
        switch operation {
        case .appCheckUpdates, .clipboardReopen, .documentSaveAsFile, .documentOpenBinder, .listToggle, .listMoveUp,
            .listMoveDown,
            .listSortByName, .binderOddPageStarts, .listRemove:
            guard currentItem(operation)?.isHidden == false else { return false }
            switch operation {
            case .appCheckUpdates: return AppUpdater.shared.isAvailable
            case .clipboardReopen: return preferences()?.closedClipboardDocuments.entries.isEmpty == false
            case .documentSaveAsFile: return model()?.canSaveAsFile == true
            case .documentOpenBinder: return model()?.includePlan != nil
            case .binderOddPageStarts, .listRemove: return model()?.binder != nil
            default: return model()?.binder != nil || model()?.imageBundle != nil
            }
        default: return true
        }
    }

    static func menuIsActive(_ operation: ShortcutOperationID, in region: ShortcutRegion?) -> Bool {
        // These clicks keep the SwiftUI action even though their keys are handled by the focused surface.
        switch operation {
        case .viewOptions: return region == .paperReading || region == .web
        case .listRemove, .viewSelectText: return region != nil
        default: return ShortcutDispatcher.isActive(operation, in: region)
        }
    }

    private func available(_ operation: ShortcutOperationID) -> Bool {
        if Self.clickOnly.contains(operation) {
            guard let current = model(), current.window === keyWindow(), commandIsPresent(operation) else {
                return false
            }
            return Self.menuIsActive(operation, in: ShortcutDispatcher.region(for: current))
        }
        return canDispatch?(operation)
            ?? (commandIsPresent(operation) && ShortcutDispatcher.isActive(operation, model: model()))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let operation = items.first(where: { $0.value === menuItem })?.key else { return false }
        return available(operation)
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let operation = items.first(where: { $0.value === sender })?.key, available(operation) else { return }
        if Self.clickOnly.contains(operation) { invokeStandard(operation) } else { dispatch(operation) }
    }

    func invokeStandard(_ operation: ShortcutOperationID) {
        if MenuTrace.noBridgeWrites {
            if let item = currentItem(operation), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            return
        }
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
