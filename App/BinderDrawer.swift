import AppKit
import SwiftUI

struct BinderDrawer: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if let binder = model.binder {
            SidePanel("Binder", subtitle: summary(binder)) {
                PanelIconButton("plus", label: "Add Documents…") { model.addBinderDocuments() }
                if model.mode == .view {
                    PanelIconButton("xmark", label: "Close") { model.isDrawerOpen = false }
                }
            } content: {
                BinderList(model: model, binder: binder)
                PanelFileIssues(
                    names: binder.unreadableURLs.map(\.lastPathComponent),
                    summary: String(
                        format: String(localized: "%lld documents could not be read"), binder.unreadableURLs.count))
                PanelFileIssues(
                    names: binder.excludedURLs.map(\.lastPathComponent),
                    summary: String(
                        format: String(localized: "%lld unsupported files excluded"), binder.excludedURLs.count))
                PanelFileIssues(names: binder.missingPaths, summary: "", status: "Not Found")
                if !binder.isSortedByName { PanelSortButton { binder.sortByName() } }
                if model.mode == .print, model.layout.hasFacingPages {
                    Toggle("Start Each Document on an Odd Page", isOn: $model.binderStartsOnFront)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func summary(_ binder: BinderModel) -> String {
        if binder.pageCounts.isEmpty { return String(format: String(localized: "%lld documents"), binder.items.count) }
        return String(
            format: String(localized: "%1$lld documents · %2$lld pages"),
            binder.items.count, binder.pageCounts.values.reduce(0, +))
    }
}

private struct BinderList: View {
    let model: DocumentViewModel
    @Bindable var binder: BinderModel
    @State private var pointedRow: URL?

    var body: some View {
        ScrollViewReader { proxy in
            List(
                selection: Binding(
                    get: { binder.selection }, set: { if let url = $0 { model.goToBinderDocument(url) } })
            ) {
                ForEach(Array(binder.items.enumerated()), id: \.element.id) { index, item in
                    BinderRow(
                        binder: binder, item: item, index: index,
                        onPoint: { isOver in
                            if isOver {
                                pointedRow = item.url
                            } else if pointedRow == item.url {
                                pointedRow = nil
                            }
                        }
                    )
                    .tag(item.url)
                    .id(item.url)
                    .contextMenu {
                        if binder.items.count > 1 { Button("Remove from List") { binder.remove(item.url) } }
                    }
                }
                .onMove { binder.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.sidebar)
            // The sidebar style insets its rows; here the panel's own padding does that.
            .padding(.horizontal, -10)
            .scrollContentBackground(.hidden)
            .background(
                SelectedRowClicks(pointedRow: pointedRow, selection: binder.selection) { model.goToBinderDocument($0) }
            )
            .onDeleteCommand { binder.removeSelection() }
            .onChange(of: binder.selection) { _, url in
                if let url { proxy.scrollTo(url) }
            }
            .accessibilityLabel("Binder")
        }
    }
}

private struct BinderRow: View {
    let binder: BinderModel
    let item: BinderModel.Item
    let index: Int
    let onPoint: (Bool) -> Void
    @State private var isHovered = false

    init(binder: BinderModel, item: BinderModel.Item, index: Int, onPoint: @escaping (Bool) -> Void) {
        self.binder = binder
        self.item = item
        self.index = index
        self.onPoint = onPoint
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: "\(index + 1)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(PrintPalette.ink3).frame(width: 16, alignment: .trailing)
                Group {
                    if let image = binder.thumbnails[item.url] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc").foregroundStyle(PrintPalette.ink3)
                    }
                }
                .frame(width: 30, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 3) {
                        Text(verbatim: item.format.badge)
                        if let count = binder.pageCounts[item.url] {
                            Text("·")
                            Text(String(format: String(localized: "%lld pages"), count))
                        }
                        if binder.unreadableURLs.contains(item.url) { Image(systemName: "exclamationmark.triangle") }
                    }
                    .font(.system(size: 11)).foregroundStyle(PrintPalette.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onHover(perform: onPoint)
            // The removal button keeps its room whether it shows or not, so the names do not move.
            Group {
                if binder.items.count > 1 {
                    PanelIconButton("xmark", label: "Remove from List") { binder.remove(item.url) }
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 22)
        }
        .onHover { isHovered = $0 }
        .help(item.name)
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
