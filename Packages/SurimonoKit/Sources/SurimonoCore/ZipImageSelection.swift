import Foundation

/// The images of an archive in display order, and what was left out.
public struct ZipImageSelection: Equatable, Sendable {
    public let images: [ZipArchive.Entry]
    public let excludedPaths: [String]

    public init(archive: ZipArchive) {
        var images: [ZipArchive.Entry] = []
        var excluded: [String] = []
        for entry in archive.entries.sorted(by: { NaturalOrder.arePathsInIncreasingOrder($0.path, $1.path) }) {
            guard !entry.isDirectory else { continue }
            let components = entry.path.split(separator: "/")
            let hidden = components.contains { $0.hasPrefix(".") }
            if components.isEmpty || hidden || components.first == "__MACOSX"
                || DocumentFormat(fileExtension: (entry.path as NSString).pathExtension) != .image
            {
                excluded.append(entry.path)
            } else {
                images.append(entry)
            }
        }
        self.images = images
        self.excludedPaths = excluded
    }
}
