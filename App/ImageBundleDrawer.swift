import AppKit
import ImageIO
import SwiftUI

struct ImageBundleDrawer: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if let bundle = model.imageBundle {
            SidePanel("Image Order", subtitle: String(format: String(localized: "%lld images"), bundle.items.count)) {
                if bundle.archiveURL == nil {
                    PanelIconButton("plus", label: "Add Documents…") { model.chooseDocumentsToAdd() }
                }
                if model.mode == .view {
                    PanelIconButton("xmark", label: "Close") { model.isDrawerOpen = false }
                }
            } content: {
                ImageBundleList(model: model, bundle: bundle)
                if bundle.archiveURL == nil { PanelDropHint() }
                PanelFileIssues(
                    names: bundle.excludedSummary,
                    summary: String(
                        format: String(localized: "%lld non-image files excluded"), bundle.excludedPaths.count))
                if !bundle.isSortedByName { PanelSortButton { bundle.sortByName() } }
            }
        }
    }
}

private struct ImageBundleList: View {
    let model: DocumentViewModel
    @Bindable var bundle: ImageBundleModel
    @State private var pointedRow: URL?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { bundle.selection }, set: { if let url = $0 { model.goToBundleImage(url) } }))
            {
                ForEach(Array(bundle.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(index + 1)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(PrintPalette.ink3).frame(width: 16, alignment: .trailing)
                        ImageThumbnail(model: bundle, item: item)
                        Text(verbatim: item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onHover { isOver in
                        if isOver {
                            pointedRow = item.url
                        } else if pointedRow == item.url {
                            pointedRow = nil
                        }
                    }
                    .tag(item.url).id(item.url).help(item.name)
                    .background {
                        if bundle.flashedURLs.contains(item.url) {
                            RoundedRectangle(cornerRadius: 6).fill(PrintPalette.aiTint2)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: { frame in
                        model.drop.rowFrames[item.url] = frame
                    }
                }
                .onMove { bundle.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.sidebar)
            // The sidebar style insets its rows; here the panel's own padding does that.
            .padding(.horizontal, -10)
            .scrollContentBackground(.hidden)
            .background(
                SelectedRowClicks(pointedRow: pointedRow, selection: bundle.selection) { model.goToBundleImage($0) }
            )
            .onChange(of: bundle.selection) { _, url in if let url { proxy.scrollTo(url) } }
            .animation(.easeOut(duration: 0.2), value: bundle.flashedURLs)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                model.drop.listFrame = frame
            }
            .onDisappear { model.drop.listFrame = nil }
            .accessibilityLabel("Images")
        }
    }
}

private struct ImageThumbnail: View {
    let model: ImageBundleModel
    let item: ImageBundleModel.Item
    @State private var image: CGImage?

    init(model: ImageBundleModel, item: ImageBundleModel.Item) {
        self.model = model
        self.item = item
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 40)
        .task(id: item) {
            guard let data = await model.data(for: item) else { return }
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            }.value
        }
    }
}
