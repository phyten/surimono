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
        let ordered = Self.sorted(unique)
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

    /// In file name order.
    public static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted {
            let comparison = NaturalOrder.compare($0.lastPathComponent, $1.lastPathComponent)
            return comparison == .orderedSame
                ? $0.absoluteString < $1.absoluteString : comparison == .orderedAscending
        }
    }

    public static func binderFormat(_ url: URL) -> DocumentFormat? {
        let format = fileFormat(url)
        return format == .zipArchive ? nil : format
    }

    /// A ZIP archive opens as a window of its own and cannot join a binder.
    public static func isArchive(_ url: URL) -> Bool { fileFormat(url) == .zipArchive }

    private static func fileFormat(_ url: URL) -> DocumentFormat? {
        guard url.isFileURL,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return nil }
        return DocumentFormat(fileExtension: url.pathExtension)
            ?? UTType(filenameExtension: url.pathExtension).flatMap { DocumentFormat(contentType: $0) }
    }
}
