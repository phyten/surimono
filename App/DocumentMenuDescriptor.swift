import SurimonoCore
import SwiftUI

/// IDs describe what a row does. Reordering a history or replacing a label never retargets a selection.
enum DocumentMenuAction: Hashable {
    case operation(ShortcutOperationID)
    case history(ContentHash)
    case recentBinder(RecentBinder.ID)
    case clearClipboard, clearBinders, openSample, checkWriting
    case composition(LaTeXComposition)
    case typeface(Typeface)
    case setting(UUID)
    case replaceSetting(UUID)

    func perform(
        preferences: AppPreferences, model: () -> DocumentViewModel? = { DocumentWindows.shared.currentModel },
        openBinder: (RecentBinder) -> Void = { OpenRouter.shared.open(recentBinder: $0) }
    ) {
        switch self {
        case .operation(let operation):
            ShortcutDispatcher.shared.performFromMenu(operation, event: NSApp.currentEvent)
        case .history(let id): ClipboardWindows.shared.reopenClosed(id)
        case .recentBinder(let id):
            if let current = preferences.recentBinders.entries.first(where: { $0.id == id }) { openBinder(current) }
        case .clearClipboard: preferences.clearClosedClipboardDocuments()
        case .clearBinders: preferences.clearRecentBinders()
        case .checkWriting: model()?.openProse()
        case .openSample: OpenRouter.shared.openSampleDocument()
        case .composition(let value): model()?.selectComposition(value)
        case .typeface(let value):
            if let current = model(), current.offersTypeface { current.setTypeface(value) }
        case .setting(let id):
            guard let current = model() else { return }
            let language = Bundle.main.preferredLocalizations.first ?? "en"
            if let set = (PrintSettingSet.builtIns(language: language) + preferences.printSettingSets)
                .first(where: { $0.id == id })
            {
                current.applyPrintSettingSet(set)
            }
        case .replaceSetting(let id):
            guard let current = model(), let set = preferences.printSettingSets.first(where: { $0.id == id }),
                current.matchesPrintSettingSet(set)
            else { return }
            current.savePrintSettingSet(named: set.name, parts: set.parts)
        }
    }
}

struct DocumentMenuDescriptor: Identifiable {
    enum ID: Hashable {
        case action(DocumentMenuAction)
        case menu(String)
        case divider(String)
        case recentDocuments
        case typefacePicker
    }

    enum Title: Equatable, ExpressibleByStringLiteral {
        case key(String)
        case verbatim(String)
        case replaceSetting(String)

        init(stringLiteral value: String) { self = .key(value) }

        var text: Text {
            switch self {
            case .key(let key): Text(LocalizedStringKey(key))
            case .verbatim(let value): Text(verbatim: value)
            case .replaceSetting(let name): Text("Replace “\(name)” with Current Settings")
            }
        }
    }

    enum Section: String, CaseIterable {
        case open, save, printItems, edit, view, help, document, appInfo
    }

    let id: ID
    let title: Title
    var subtitle: String?
    var checked: Bool?
    var children: [Self] = []
    private(set) var shortcut: KeyboardShortcut?
    private(set) var isEnabled = true

    var operation: ShortcutOperationID? {
        if case .action(.operation(let operation)) = id { return operation }
        return nil
    }

    struct Modifiers {
        let shortcut: KeyboardShortcut?
        let disabled: Bool
    }

    func modifiers(inMenuBar: Bool) -> Modifiers {
        Modifiers(shortcut: inMenuBar ? shortcut : nil, disabled: !isEnabled)
    }

    private func resolved(in snapshot: MenuSnapshot) -> Self {
        var row = self
        row.children = children.map { $0.resolved(in: snapshot) }
        switch id {
        case .action(.operation(let operation)):
            // Open keeps its platform equivalent (and System Settings overrides); in-app bindings are aliases.
            row.shortcut =
                operation == .appOpen ? KeyboardShortcut("o", modifiers: .command) : snapshot.shortcut(for: operation)
            row.isEnabled = snapshot.content.enabled.contains(operation)
        case .action(.checkWriting): row.isEnabled = snapshot.content.offersProse
        case .action(.setting), .action(.replaceSetting): row.isEnabled = snapshot.content.region != nil
        case .menu, .typefacePicker:
            row.isEnabled = row.children.contains { child in
                if case .divider = child.id { return false }
                return child.isEnabled
            }
        default: break
        }
        return row
    }

    private static func button(_ title: Title, _ action: DocumentMenuAction, checked: Bool? = nil) -> Self {
        Self(id: .action(action), title: title, checked: checked)
    }

    private static func command(_ title: Title, _ operation: ShortcutOperationID, checked: Bool? = nil) -> Self {
        button(title, .operation(operation), checked: checked)
    }

    private static func menu(_ key: String, _ children: [Self]) -> Self {
        Self(id: .menu(key), title: .key(key), children: children)
    }

    private static func divider(_ before: String) -> Self { Self(id: .divider(before), title: "") }

    static func rows(for section: Section, in snapshot: MenuSnapshot) -> [Self] {
        sectionRows(section, state: snapshot.content).map { $0.resolved(in: snapshot) }
    }

    private static func sectionRows(_ section: Section, state: MenuSnapshot.Content) -> [Self] {
        switch section {
        case .open:
            var rows: [Self] = [
                command("Open…", .appOpen),
                Self(id: .recentDocuments, title: "Open Recent"),
                command("Open from Clipboard", .clipboardOpen),
                command("Open Clipboard on the Print Screen", .clipboardOpenPrintScreen),
                command("Open from URL…", .appOpenURL),
            ]
            if state.visibility.hasHistory {
                rows.append(command("Reopen Closed Clipboard Document", .clipboardReopen))
                rows.append(
                    menu(
                        "Recently Closed Clipboard Documents",
                        state.history.map {
                            button(.verbatim($0.title), .history($0.id))
                        } + [divider("clear"), button("Clear Closed Clipboard Documents", .clearClipboard)]))
            }
            rows.append(command("Streaming Preview", .appStreamingPreview))
            if !state.recentBinders.isEmpty {
                rows.append(
                    menu(
                        "Recent Binders",
                        state.recentBinders.map {
                            button(.verbatim($0.title), .recentBinder($0.id))
                        } + [divider("clear"), button("Clear Menu", .clearBinders)]))
            }
            return rows
        case .save: return state.visibility.canSaveAsFile ? [command("Save as File…", .documentSaveAsFile)] : []
        case .printItems:
            return [
                command(state.printing ? "Print" : "Print…", .documentPrint),
                command("Print with System Dialog…", .documentPrintSystem),
                menu(
                    "Export",
                    [
                        command("PDF for Reading…", .documentExportReadingPDF),
                        command("PDF of Sheets…", .documentExportPDF),
                        command("Images (PNG)…", .documentExportPNG), command("HTML…", .documentExportHTML),
                        divider("share"), command("Share PDF…", .documentShare),
                    ]),
            ]
        case .edit:
            return [
                divider("copy"), command("Copy as HTML", .documentCopyHTML),
                command("Copy as Rich Text", .documentCopyRichText),
                divider("find"), command("Find…", .documentFind), command("Find Next", .documentFindNext),
                command("Find Previous", .documentFindPrevious),
            ]
        case .view: return viewRows(state)
        case .help:
            return [
                command("Getting Started with Surimono", .appGettingStarted),
                button("Open Sample Document", .openSample),
                command("Keys and Gestures", .appKeyGuide),
            ]
        case .document: return documentRows(state)
        case .appInfo: return state.visibility.canCheckUpdates ? [command("Check for Updates…", .appCheckUpdates)] : []
        }
    }

    private static func viewRows(_ state: MenuSnapshot.Content) -> [Self] {
        var rows: [Self] = [
            command(state.showsPaper ? "Show as Web" : "Show as Paper", .viewHtmlPresentation),
            command("Show as Slides", .viewIgnoreSlides, checked: state.showsSlides), divider("layout"),
        ]
        rows += ViewOptions.Layout.displayOrder.map {
            $0 == .single ? command("Single Page", .viewSingle) : command("Spread", .viewSpread)
        }
        rows += [
            command("View Options…", .viewOptions), command("Go to Page…", .documentGoToPage),
            button("Check Writing", .checkWriting),
            command("Back", .readingBack), command("Forward", .readingForward), divider("bookmark"),
            command("Bookmark This Page", .bookmarkToggle, checked: state.bookmarked),
            command("Next Bookmark", .bookmarkNext), command("Previous Bookmark", .bookmarkPrevious), divider("text"),
            command("Increase Text Size", .textIncrease), command("Decrease Text Size", .textDecrease),
            command("Original Text Size", .textReset),
        ]
        if let selected = state.composition {
            rows.append(
                menu(
                    "LaTeX Layout",
                    LaTeXComposition.allCases.map {
                        button(.key($0.titleKey), .composition($0), checked: selected == $0)
                    }))
        }
        if let selected = state.typeface {
            rows.append(
                Self(
                    id: .typefacePicker, title: "Typeface",
                    children: [
                        button("As the Style", .typeface(.style), checked: selected == .style),
                        button("LaTeX Typeface", .typeface(.latex), checked: selected == .latex),
                    ]))
        }
        rows += [
            divider("zoom"), command("Zoom In", .viewZoomIn), command("Zoom Out", .viewZoomOut),
            command("Fit to Window", .viewZoomFit), divider("select"),
            command("Select Text", .viewSelectText, checked: state.selectingText),
            command("Always Show Toolbar", .viewToolbarAlways, checked: state.toolbarAlways),
            command("Float on Top", .viewFloatOnTop, checked: state.floatOnTop),
            command("Show on All Spaces", .viewShowOnAllSpaces, checked: state.allSpaces),
        ]
        return rows
    }

    private static func documentRows(_ state: MenuSnapshot.Content) -> [Self] {
        var layouts: [Self] = []
        for operation in ShortcutPrintLayouts.operations {
            if operation == .printLayoutTwoUpSmall { layouts.append(divider("compact")) }
            if let layout = ShortcutPrintLayouts.layout(for: operation, series: state.series) {
                layouts.append(command(.verbatim(layout.displayName(language: state.language)), operation))
            }
        }
        var rows = [
            menu("Print Layout", layouts),
            menu("Setting Sets", settingRows(builtIns: state.builtInSets, saved: state.savedSets)),
            command("Print Settings…", .printSettings), command("Choose Style…", .styleChoose),
        ]
        if state.visibility.canOpenBinder { rows.append(command("Open as Binder", .documentOpenBinder)) }
        rows.append(command("Add Documents…", .documentAdd))
        if state.visibility.hasBinder || state.visibility.hasImages {
            var list = [command("Show List", .listToggle, checked: state.drawerOpen)]
            if state.visibility.hasBinder {
                list += [
                    command("Remove from List", .listRemove),
                    command("Start Each Document on an Odd Page", .binderOddPageStarts, checked: state.oddStarts),
                ]
            }
            list += [
                command(state.visibility.hasBinder ? "Move Document Up" : "Move Image Up", .listMoveUp),
                command(state.visibility.hasBinder ? "Move Document Down" : "Move Image Down", .listMoveDown),
                command("Sort by Name", .listSortByName),
            ]
            rows.append(menu(state.visibility.hasBinder ? "Binder" : "Images", list))
        }
        return rows + [
            divider("reset"), command("Reset Document Settings", .documentResetSettings),
            command("Reload", .documentReload),
        ]
    }

    static func settingRows(builtIns: [MenuSnapshot.SettingEntry], saved: [MenuSnapshot.SettingEntry]) -> [Self] {
        func setting(_ entry: MenuSnapshot.SettingEntry) -> Self {
            Self(
                id: .action(.setting(entry.id)), title: .verbatim(entry.name), subtitle: entry.subtitle,
                checked: entry.checked)
        }
        var rows = builtIns.map { setting($0) }
        if !saved.isEmpty { rows += [divider("saved")] + saved.map { setting($0) } }
        rows += [divider("save"), command("Save Current Settings…", .settingSetSave)]
        rows += saved.filter(\.checked).map { button(.replaceSetting($0.name), .replaceSetting($0.id)) }
        return rows + [divider("manage"), command("Manage Setting Sets…", .settingSetManage)]
    }
}
