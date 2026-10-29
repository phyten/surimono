import Foundation
import UniformTypeIdentifiers

public enum OpenRequest: Equatable, Sendable {
    case single(URL)
    case imageBundle([URL])
    case rejectedMultipleNonImages
    case empty

    public init(urls: [URL]) {
        guard let first = urls.first else {
            self = .empty
            return
        }
        guard urls.count > 1 else {
            self = .single(first)
            return
        }
        guard urls.allSatisfy(Self.isImage) else {
            self = .rejectedMultipleNonImages
            return
        }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        self = .imageBundle(
            unique.sorted {
                let comparison = NaturalOrder.compare($0.lastPathComponent, $1.lastPathComponent)
                // Preserve a deterministic order for identical names in different directories.
                return comparison == .orderedSame
                    ? $0.absoluteString < $1.absoluteString : comparison == .orderedAscending
            })
    }

    /// Resolves the format as a single opened document does: the extension table first, then the content type, which
    /// covers readable images such as PSD that the table does not list.
    private static func isImage(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension
        let format =
            DocumentFormat(fileExtension: fileExtension)
            ?? UTType(filenameExtension: fileExtension).flatMap { DocumentFormat(contentType: $0) }
        return format == .image
    }
}
