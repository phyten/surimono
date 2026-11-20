import SurimonoCore
import SwiftUI

struct DocumentCommands: Commands {
    let preferences: AppPreferences
    let menuState: MenuState

    private func items(_ section: DocumentMenuDescriptor.Section) -> some View {
        DocumentMenuSection(section: section, preferences: preferences, state: menuState)
    }

    var body: some Commands {
        let _ = MenuTrace.commandsBody("DocumentCommands", version: menuState.snapshot.version)
        CommandGroup(replacing: .newItem) { items(.open) }
        CommandGroup(after: .saveItem) { items(.save) }
        CommandGroup(replacing: .printItem) { items(.printItems) }
        CommandGroup(after: .pasteboard) { items(.edit) }
        CommandGroup(after: .toolbar) { items(.view) }
        CommandGroup(replacing: .help) { items(.help) }
        CommandMenu("Document") { items(.document) }
        CommandGroup(after: .appInfo) { items(.appInfo) }
    }
}

/// SwiftUI observes the view that supplies a command group's items even when it caches the enclosing Commands.
private struct DocumentMenuSection: View {
    let section: DocumentMenuDescriptor.Section
    let preferences: AppPreferences
    let state: MenuState

    var body: some View {
        let snapshot = state.snapshot
        let _ = MenuTrace.commandsBody("DocumentCommands.\(section.rawValue)", version: snapshot.version)
        DocumentMenuRows(rows: DocumentMenuDescriptor.rows(for: section, in: snapshot), inMenuBar: true) {
            $0.perform(preferences: preferences)
        }
    }
}

struct DocumentMenuRows: View {
    let rows: [DocumentMenuDescriptor]
    var inMenuBar = false
    let perform: (DocumentMenuAction) -> Void

    var body: some View {
        ForEach(rows) { row in
            switch row.id {
            case .divider: Divider()
            case .menu:
                Menu {
                    DocumentMenuRows(rows: row.children, inMenuBar: inMenuBar, perform: perform)
                } label: {
                    row.title.text
                }
            case .typefacePicker:
                Picker(
                    selection: Binding(
                        get: { row.children.first { $0.checked == true }?.id },
                        set: { id in if case .action(let action) = id { perform(action) } }
                    )
                ) {
                    ForEach(row.children) { choice in choice.title.text.tag(Optional(choice.id)) }
                } label: {
                    row.title.text
                }.pickerStyle(.menu)
            case .action(let action):
                if inMenuBar, let operation = row.operation {
                    // Native validation keeps the displayed availability and a rebound key on the same live target.
                    button(row, action: action)
                        .accessibilityIdentifier(ShortcutMenuBridge.identifier(operation).rawValue)
                        .keyboardShortcut(row.shortcut)
                } else {
                    button(row, action: action)
                }
            }
        }
    }

    @ViewBuilder private func button(_ row: DocumentMenuDescriptor, action: DocumentMenuAction) -> some View {
        if let checked = row.checked {
            Toggle(isOn: Binding(get: { checked }, set: { _ in perform(action) })) {
                row.title.text
                if let subtitle = row.subtitle { Text(verbatim: subtitle) }
            }
        } else {
            Button {
                perform(action)
            } label: {
                row.title.text
            }
        }
    }
}
