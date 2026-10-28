import AppKit
import ImageIO
import SwiftUI

struct ImageBundleSidebar: View {
    @Bindable var model: ImageBundleModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.urls, id: \.self) { url in
                HStack {
                    ImageThumbnail(url: url)
                    Text(verbatim: url.lastPathComponent).lineLimit(2)
                }
                .tag(url)
                .help(url.lastPathComponent)
            }
            .onMove { offsets, destination in model.move(fromOffsets: offsets, toOffset: destination) }
        }
        .frame(width: 200)
        .accessibilityLabel("Images")
    }
}

private struct ImageThumbnail: View {
    let url: URL
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
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
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
