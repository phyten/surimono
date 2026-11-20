import AppKit
import Observation
import SurimonoCore
import SwiftUI

/// A revision describes exactly one presentation. Comparing content separately keeps the version out of change detection.
struct MenuSnapshot: Equatable {
    typealias Entry = ClosedClipboardDocuments.MenuItem

    struct BinderEntry: Identifiable, Equatable {
        let id: RecentBinder.ID
        let title: String
    }

    struct SettingEntry: Identifiable, Equatable {
        let id: UUID
        let name: String
        let subtitle: String
        let checked: Bool

        init(_ set: PrintSettingSet, model: DocumentViewModel?, summary: SettingSetSummary) {
            id = set.id
            name = set.name
            subtitle = summary.subtitle(set)
            checked = model?.matchesPrintSettingSet(set) == true
        }
    }

    struct Visibility: Equatable {
        let hasHistory: Bool
        let canCheckUpdates: Bool
        let canSaveAsFile: Bool
        let canOpenBinder: Bool
        let hasBinder: Bool
        let hasImages: Bool

        init(model: DocumentViewModel?, preferences: AppPreferences?) {
            hasHistory = preferences?.closedClipboardDocuments.entries.isEmpty == false
            canCheckUpdates = AppUpdater.shared.isAvailable
            canSaveAsFile = model?.canSaveAsFile == true
            canOpenBinder = model?.includePlan != nil
            hasBinder = model?.binder != nil
            hasImages = model?.imageBundle != nil
        }

        func contains(_ operation: ShortcutOperationID) -> Bool {
            switch operation {
            case .clipboardReopen: hasHistory
            case .documentSaveAsFile: canSaveAsFile
            case .documentOpenBinder: canOpenBinder
            case .binderOddPageStarts, .listRemove: hasBinder
            case .listToggle, .listMoveUp, .listMoveDown, .listSortByName: hasBinder || hasImages
            case .appCheckUpdates: canCheckUpdates
            default: true
            }
        }
    }

    struct Content: Equatable {
        let enabled: Set<ShortcutOperationID>
        let automaticMenuKeys: [ShortcutOperationID: ShortcutCombination]
        let effectiveKeys: [ShortcutOperationID: [ShortcutCombination]]
        let builtInSets: [SettingEntry]
        let savedSets: [SettingEntry]
        let typeface: Typeface?
        let selectingText: Bool
        let history: [Entry]
        let recentBinders: [BinderEntry]
        let visibility: Visibility
        let region: ShortcutRegion?
        let printing: Bool
        let showsPaper: Bool
        let showsSlides: Bool
        let bookmarked: Bool
        let toolbarAlways: Bool
        let floatOnTop: Bool
        let allSpaces: Bool
        let drawerOpen: Bool
        let oddStarts: Bool
        let series: PaperSeries
        let language: String

        init(
            model: DocumentViewModel? = nil, preferences: AppPreferences? = nil, library: UserLibrary? = nil,
            marginUnit: MarginUnit = .current, controller: ShortcutController = .shared, textInput: Bool = false
        ) {
            let language = model?.language ?? Bundle.main.preferredLocalizations.first ?? "en"
            self.language = language
            let summary = SettingSetSummary(
                themes: library?.themes ?? [], presets: library?.presets ?? [], language: language, unit: marginUnit)
            builtInSets = PrintSettingSet.builtIns(language: language).map {
                SettingEntry($0, model: model, summary: summary)
            }
            savedSets = preferences?.printSettingSets.map { SettingEntry($0, model: model, summary: summary) } ?? []
            let operations = SystemMenuShortcuts.operations
            let resolved = Dictionary(
                uniqueKeysWithValues: operations.map { ($0, controller.localKeys(for: $0, textInput: textInput)) })
            effectiveKeys = resolved
            automaticMenuKeys = Dictionary(
                uniqueKeysWithValues: operations.compactMap { operation in
                    controller.automaticMenuKey(for: operation, effective: resolved[operation]?.first).map {
                        (operation, $0)
                    }
                })
            let visibility = Visibility(model: model, preferences: preferences)
            self.visibility = visibility
            enabled = Set(
                operations.filter { ShortcutDispatcher.isAvailable($0, model: model, visibility: visibility) })
            history = preferences?.closedClipboardDocuments.entries.map(\.menuItem) ?? []
            recentBinders =
                preferences?.recentBinders.entries.map {
                    BinderEntry(
                        id: $0.id,
                        title: BinderModel.title(firstName: $0.firstName, count: $0.files.count, language: language))
                } ?? []
            typeface = model?.offersTypeface == true ? model?.typeface : nil
            selectingText = model?.isSelectingText == true
            region = ShortcutDispatcher.region(for: model)
            printing = model?.mode == .print
            showsPaper = model?.htmlPresentation == .paper
            showsSlides = model?.slideDeck != nil
            bookmarked = model?.isVisiblePageBookmarked == true
            toolbarAlways = model?.isBandAlwaysVisible == true
            floatOnTop = model?.isAlwaysOnTop == true
            allSpaces = model?.showsOnAllSpaces == true
            drawerOpen = model?.isDrawerOpen == true
            oddStarts = model?.binderStartsOnFront == true
            series = model?.trayPaperSeries ?? .a
        }
    }

    let version: UInt64
    let content: Content

    func shortcut(for operation: ShortcutOperationID) -> KeyboardShortcut? {
        let automatic = content.automaticMenuKeys[operation]
        guard let binding = automatic ?? content.effectiveKeys[operation]?.first,
            !binding.modifiers.intersection([.command, .control]).isEmpty,
            let character = ShortcutMenuKey.character(binding.key)?.first
        else { return nil }
        var modifiers: EventModifiers = []
        if binding.modifiers.contains(.command) { modifiers.insert(.command) }
        if binding.modifiers.contains(.control) { modifiers.insert(.control) }
        if binding.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if binding.modifiers.contains(.option) { modifiers.insert(.option) }
        return KeyboardShortcut(
            KeyEquivalent(character), modifiers: modifiers, localization: automatic == nil ? .custom : .automatic)
    }
}

@Observable
final class MenuState {
    private(set) var snapshot = MenuSnapshot(version: 0, content: .init())

    func publish(_ content: MenuSnapshot.Content) {
        guard content != snapshot.content else { return }
        snapshot = MenuSnapshot(version: snapshot.version + 1, content: content)
        MenuTrace.record("publish version=\(snapshot.version)")
    }
}
