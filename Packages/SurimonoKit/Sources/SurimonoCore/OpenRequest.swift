import Foundation

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
        guard urls.allSatisfy({ DocumentFormat(fileExtension: $0.pathExtension) == .image }) else {
            self = .rejectedMultipleNonImages
            return
        }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        self = .imageBundle(
            unique.sorted {
                let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                // Preserve a deterministic order for identical names in different directories.
                return comparison == .orderedSame
                    ? $0.absoluteString < $1.absoluteString : comparison == .orderedAscending
            })
    }
}
