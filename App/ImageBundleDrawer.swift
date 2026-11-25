import AppKit
import ImageIO
import SwiftUI

struct ImageBundleDrawer: View {
    @Bindable var model: DocumentViewModel

    var body: some View {
        if let bundle = model.imageBundle {
            SidePanel("Image Order", subtitle: String(format: String(localized: "%lld images"), bundle.items.count)) {
                if bundle.archiveURL == nil {
                    PanelIconButton("plus", label: "Add Documents…") { [weak model] in
                        guard let model, !model.isWindowClosed else { return }
                        model.chooseDocumentsToAdd()
                    }
                }
                if model.mode == .view {
                    PanelIconButton("xmark", label: "Close") { [weak model] in
                        guard let model, !model.isWindowClosed else { return }
                        model.setSideListOpen(false)
                    }
                }
            } content: {
                ImageBundleList(model: model, bundle: bundle)
                BundlePageActions(model: model, bundle: bundle)
            }
        }
    }
}

struct BundlePageActions: View {
    let model: DocumentViewModel
    let bundle: ImageBundleModel

    var body: some View {
        if bundle.archiveURL == nil, model.drop.isActive { PanelDropHint() }
        PanelFileIssues(
            names: bundle.excludedSummary,
            summary: String(
                format: String(localized: "%lld non-image files excluded"), bundle.excludedPaths.count))
        if !bundle.isSortedByName {
            PanelSortButton { [weak model] in
                guard let model, !model.isWindowClosed else { return }
                model.imageBundle?.sortByName()
            }
        }
    }
}

private struct ImageBundleList: View {
    let model: DocumentViewModel
    @Bindable var bundle: ImageBundleModel
    @State private var pointedRow: URL?

    var body: some View {
        let select = model.windowAction { $0.goToBundleImage($1) }
        let selection = model.controlBinding(
            get: { $0.imageBundle?.selection }, set: { model, url in if let url { model.goToBundleImage(url) } })
        return ScrollViewReader { [weak model, bundle, pointedRow = $pointedRow] proxy in
            List(selection: selection) {
                ForEach(Array(bundle.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 6) {
                        Text(verbatim: "\(index + 1)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(
                                bundle.selection == item.url
                                    ? AnyShapeStyle(.primary) : AnyShapeStyle(PrintPalette.ink3)
                            ).frame(width: 16, alignment: .trailing)
                        ImageThumbnail(model: bundle, item: item)
                        Text(verbatim: item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onHover { isOver in
                        if isOver {
                            pointedRow.wrappedValue = item.url
                        } else if pointedRow.wrappedValue == item.url {
                            pointedRow.wrappedValue = nil
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: item.name))
                    .accessibilityValue(Text("Page \(index + 1)"))
                    .tag(item.url).id(item.url).help(item.name)
                    .background {
                        if bundle.flashedURLs.contains(item.url) {
                            CornerRole.control.shape.fill(PrintPalette.aiTint2)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: { [weak model] frame in
                        guard let model, !model.isWindowClosed else { return }
                        model.drop.rowFrames[item.url] = frame
                    }
                }
                .onMove { [weak model] offsets, destination in
                    guard let model, !model.isWindowClosed else { return }
                    bundle.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.sidebar)
            // The sidebar style insets its rows; here the panel's own padding does that.
            .padding(.horizontal, -10)
            .scrollContentBackground(.hidden)
            .background(
                SelectedRowClicks(
                    pointedRow: pointedRow.wrappedValue, selection: bundle.selection, onClick: select)
            )
            .onChange(of: bundle.selection) { _, url in if let url { proxy.scrollTo(url) } }
            .animation(.easeOut(duration: 0.2), value: bundle.flashedURLs)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { [weak model] frame in
                guard let model, !model.isWindowClosed else { return }
                model.drop.listFrame = frame
            }
            .onDisappear { [weak model] in
                guard let model, !model.isWindowClosed else { return }
                model.drop.listFrame = nil
            }
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
                Image(systemName: "photo").foregroundStyle(PrintPalette.ink2)
            }
        }
        .accessibilityHidden(true)
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
