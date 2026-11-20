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

    struct Content: Equatable {
        let overrides: [ShortcutOperationID: [ShortcutCombination]]
        let builtInSets: [SettingEntry]
        let savedSets: [SettingEntry]
        let typeface: Typeface?
        let selectingText: Bool
        let history: [Entry]
        let recentBinders: [BinderEntry]
        let canCheckUpdates: Bool
        let canSaveAsFile: Bool
        let canOpenBinder: Bool
        let hasBinder: Bool
        let hasImages: Bool
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
            marginUnit: MarginUnit = .current
        ) {
            let language = model?.language ?? Bundle.main.preferredLocalizations.first ?? "en"
            self.language = language
            let summary = SettingSetSummary(
                themes: library?.themes ?? [], presets: library?.presets ?? [], language: language, unit: marginUnit)
            builtInSets = PrintSettingSet.builtIns(language: language).map {
                SettingEntry($0, model: model, summary: summary)
            }
            savedSets = preferences?.printSettingSets.map { SettingEntry($0, model: model, summary: summary) } ?? []
            overrides = preferences?.keyboardShortcuts.overrides ?? [:]
            history = preferences?.closedClipboardDocuments.entries.map(\.menuItem) ?? []
            recentBinders =
                preferences?.recentBinders.entries.map {
                    BinderEntry(
                        id: $0.id,
                        title: BinderModel.title(firstName: $0.firstName, count: $0.files.count, language: language))
                } ?? []
            canCheckUpdates = AppUpdater.shared.isAvailable
            typeface = model?.offersTypeface == true ? model?.typeface : nil
            selectingText = model?.isSelectingText == true
            canSaveAsFile = model?.canSaveAsFile == true
            canOpenBinder = model?.includePlan != nil
            hasBinder = model?.binder != nil
            hasImages = model?.imageBundle != nil
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
        let override = content.overrides[operation]
        guard let binding = (override ?? ShortcutDefaults.keys(for: operation)).first,
            !binding.modifiers.intersection([.command, .control]).isEmpty,
            let character = ShortcutMenuKey.character(binding.key)?.first
        else { return nil }
        var modifiers: EventModifiers = []
        if binding.modifiers.contains(.command) { modifiers.insert(.command) }
        if binding.modifiers.contains(.control) { modifiers.insert(.control) }
        if binding.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if binding.modifiers.contains(.option) { modifiers.insert(.option) }
        return KeyboardShortcut(
            KeyEquivalent(character), modifiers: modifiers, localization: override == nil ? .automatic : .custom)
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
