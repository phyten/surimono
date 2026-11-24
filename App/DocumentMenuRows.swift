import SwiftUI

struct DocumentMenuRows: View {
    let rows: [DocumentMenuDescriptor]
    let perform: (DocumentMenuAction) -> Void

    var body: some View {
        ForEach(rows) { row in
            switch row.id {
            case .divider: Divider()
            case .recentDocuments: EmptyView()
            case .menu:
                Menu {
                    DocumentMenuRows(rows: row.children, perform: perform)
                } label: {
                    row.title.text
                }.disabled(!row.isEnabled)
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
                }.pickerStyle(.menu).disabled(!row.isEnabled)
            case .action(let action):
                button(row, action: action).disabled(!row.isEnabled)
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
