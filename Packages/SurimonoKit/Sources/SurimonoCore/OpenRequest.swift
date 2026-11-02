import Foundation
import UniformTypeIdentifiers

public enum OpenRequest: Equatable, Sendable {
    case single(URL)
    case imageBundle([URL], excluded: [URL] = [])
    case binder([URL], excluded: [URL])
    case unsupported
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
        var seen = Set<URL>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        let ordered = unique.sorted {
            let comparison = NaturalOrder.compare($0.lastPathComponent, $1.lastPathComponent)
            return comparison == .orderedSame
                ? $0.absoluteString < $1.absoluteString : comparison == .orderedAscending
        }
        let readable = ordered.filter { Self.binderFormat($0) != nil }
        let excluded = ordered.filter { Self.binderFormat($0) == nil }
        guard !readable.isEmpty else {
            self = .unsupported
            return
        }
        if readable.allSatisfy({ Self.binderFormat($0) == .image }) {
            self = .imageBundle(readable, excluded: excluded)
        } else {
            self = .binder(readable, excluded: excluded)
        }
    }

    public static func binderFormat(_ url: URL) -> DocumentFormat? {
        guard url.isFileURL,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return nil }
        let format =
            DocumentFormat(fileExtension: url.pathExtension)
            ?? UTType(filenameExtension: url.pathExtension).flatMap { DocumentFormat(contentType: $0) }
        return format == .zipArchive ? nil : format
    }
}
