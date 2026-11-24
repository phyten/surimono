import AppKit
import SurimonoCore

@MainActor
final class SystemMenuShortcuts {
    static let operations: Set<ShortcutOperationID> = Set([
        .appOpen, .appSettings, .appOpenURL, .clipboardReopen, .clipboardOpen,
        .clipboardOpenPrintScreen, .documentPrint, .documentPrintSystem, .documentExportPDF, .documentExportReadingPDF,
        .documentExportPNG, .documentExportHTML, .documentCopyHTML, .documentCopyRichText, .documentShare,
        .printSettings, .appStreamingPreview, .documentSaveAsFile, .documentFind, .documentFindNext,
        .documentFindPrevious, .viewHtmlPresentation, .viewOptions, .viewSelectText, .listRemove,
        .viewIgnoreSlides, .viewSingle, .viewSpread, .documentGoToPage, .documentGoToLine, .readingBack,
        .readingForward, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious, .textIncrease,
        .textDecrease, .textReset, .viewZoomIn, .viewZoomOut, .viewZoomFit,
        .viewToolbarAlways, .viewFloatOnTop, .viewShowOnAllSpaces, .appGettingStarted, .appKeyGuide,
        .appCheckUpdates, .documentOpenBinder, .documentAdd, .styleChoose, .documentResetSettings,
        .documentReload, .settingSetSave, .settingSetManage, .listToggle, .listMoveUp,
        .listMoveDown, .listSortByName, .binderOddPageStarts,
    ]).union(ShortcutPrintLayouts.operations)

    static func accessibilityID(_ operation: ShortcutOperationID) -> String {
        "surimono.shortcut." + operation.rawValue
    }

    private let controller: ShortcutController
    let menuState = MenuState()
    let preferences: () -> AppPreferences?
    private let externalKey: (NSMenuItem) -> String
    // Conditional rows can leave the menu and be deallocated. Their identities must expire with them.
    private let operationsByItem = NSMapTable<NSMenuItem, NSString>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    init(
        controller: ShortcutController, preferences: @escaping () -> AppPreferences? = { AppPreferences.shared },
        externalKey: @escaping (NSMenuItem) -> String = { $0.userKeyEquivalent }
    ) {
        self.controller = controller
        self.preferences = preferences
        self.externalKey = externalKey
    }

    func register(_ item: NSMenuItem, for operation: ShortcutOperationID) {
        operationsByItem.setObject(operation.rawValue as NSString, forKey: item)
    }

    /// AppKit applies system App Shortcuts and keyboard-layout translations to the installed items.
    /// Observe only rows actually reachable from the root. A renamed or translated row keeps its operation.
    func readKeys(in root: NSMenu) {
        var external: [ShortcutOperationID: ShortcutCombination] = [:]
        var standard: [ShortcutOperationID: ShortcutCombination] = [:]
        var localized: [ShortcutOperationID: ShortcutCombination] = [:]
        var native: Set<ShortcutCombination> = []
        func visit(_ menu: NSMenu) {
            for item in menu.items where !item.isHidden {
                if let submenu = item.submenu {
                    visit(submenu)
                } else if let id = operationsByItem.object(forKey: item),
                    let operation = ShortcutOperationID(rawValue: id as String)
                {
                    let key = ShortcutMenuKey(item: item).combination
                    if !externalKey(item).isEmpty {
                        external[operation] = key
                    } else if operation == .appOpen || operation == .appSettings {
                        standard[operation] = key
                    } else if item.allowsAutomaticKeyEquivalentLocalization, item.allowsAutomaticKeyEquivalentMirroring,
                        controller.snapshot.overrides[operation] == nil
                    {
                        localized[operation] = key
                    }
                } else if !externalKey(item).isEmpty, let key = ShortcutMenuKey(item: item).combination {
                    native.insert(key)
                }
            }
        }
        visit(root)
        controller.observeLocalizedDefaults(localized)
        controller.setExternalMenuKeys(external, standard: standard, native: native)
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
