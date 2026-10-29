import AppKit
import ImageIO
import SwiftUI

/// The thumbnails of an image bundle, shown from the overlay menu to reorder the images.
struct ImageBundleDrawer: View {
    @Bindable var model: ImageBundleModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Image Order").font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
            }
            Text("Drag to reorder, or move the selected image with ⌥⌘↑ and ⌥⌘↓.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            if !model.excludedPaths.isEmpty {
                Text(String(format: String(localized: "%lld non-image files excluded"), model.excludedPaths.count))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    .help(model.excludedPaths.joined(separator: "\n"))
            }
            ImageBundleList(model: model)
                .scrollContentBackground(.hidden)
                .padding(.vertical, 6)
            Button("Sort by Name") { model.sortByName() }
                .frame(maxWidth: .infinity)
                .disabled(model.isSortedByName)
        }
        .padding(12)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityLabel("Images")
    }
}

/// The images of a bundle in order, with numbers and thumbnails; drag to reorder. Used by the view mode's drawer and
/// the print mode's sidebar.
struct ImageBundleList: View {
    @Bindable var model: ImageBundleModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    ImageThumbnail(model: model, item: item)
                    Text(verbatim: item.name).font(.callout).lineLimit(2).truncationMode(.middle)
                }
                .tag(item.url)
                .help(item.name)
            }
            .onMove { offsets, destination in model.move(fromOffsets: offsets, toOffset: destination) }
        }
        .listStyle(.plain)
        .accessibilityLabel("Images")
    }
}

private struct ImageThumbnail: View {
    let model: ImageBundleModel
    let item: ImageBundleModel.Item
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
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
