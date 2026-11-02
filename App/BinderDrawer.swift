import AppKit
import SwiftUI

struct BinderDrawer: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if let binder = model.binder {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Binder").font(.headline)
                    Spacer()
                    if model.mode == .view {
                        Button {
                            model.isDrawerOpen = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain).help("Close")
                    }
                }
                Text("Drag to reorder, or move the selected document with ⌥⌘↑ and ⌥⌘↓.")
                    .font(.caption).foregroundStyle(.secondary)
                if !binder.excludedURLs.isEmpty {
                    Text(
                        String(format: String(localized: "%lld unsupported files excluded"), binder.excludedURLs.count)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .help(binder.excludedURLs.map(\.lastPathComponent).joined(separator: "\n"))
                }
                if !binder.unreadableURLs.isEmpty {
                    Text(
                        String(
                            format: String(localized: "%lld documents could not be read"), binder.unreadableURLs.count)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .help(binder.unreadableURLs.map(\.lastPathComponent).joined(separator: "\n"))
                }
                BinderList(model: binder)
                HStack {
                    Button("Add Documents…") { model.addBinderDocuments() }
                    Spacer()
                    Button {
                        binder.removeSelection()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Remove Document").disabled(binder.selection == nil)
                }
                Button("Sort by Name") { binder.sortByName() }.disabled(binder.isSortedByName)
                Toggle("Start Each Document on the Front", isOn: $model.binderStartsOnFront)
                    .font(.caption)
            }
            .padding(12)
            .frame(width: 260)
            .paperOverlayBackground(cornerRadius: 12)
        }
    }
}

private struct BinderList: View {
    @Bindable var model: BinderModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Group {
                        if let image = model.thumbnails[item.url] {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 48, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "\(index + 1). \(item.name)")
                            .font(.callout).lineLimit(2).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text(verbatim: item.format.badge)
                            if let count = model.pageCounts[item.url] {
                                Text("·")
                                Text(String(format: String(localized: "%lld pages"), count))
                            }
                            if model.unreadableURLs.contains(item.url) { Image(systemName: "exclamationmark.triangle") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(item.url).help(item.name)
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Binder")
    }
}

extension DocumentViewModel {
    func addBinderDocuments() {
        guard let binder else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SurimonoDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { binder.add(panel.urls) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
