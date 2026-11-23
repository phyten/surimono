import Foundation
import UniformTypeIdentifiers

public enum OpenRequest: Equatable, Sendable {
    case single(URL)
    case imageBundle([URL], excluded: [URL] = [])
    case binder([URL], excluded: [URL])
    case unsupported
    case empty

    public init(urls: [URL]) {
        self.init(urls: urls, formats: FileFormats())
    }

    /// `formats` holds one decision per file, so that a plan that asked about a file already does not read it again.
    init(urls: [URL], formats: FileFormats) {
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
        let readable = ordered.filter { formats.binderFormat($0) != nil }
        let excluded = ordered.filter { formats.binderFormat($0) == nil }
        guard !readable.isEmpty else {
            self = .unsupported
            return
        }
        if readable.allSatisfy({ formats.binderFormat($0) == .image }) {
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

    /// The format a file has in a binder, or nil when it cannot join one. With `root`, a file that is read to find
    /// out must lie under that folder.
    public static func binderFormat(_ url: URL, within root: String? = nil) -> DocumentFormat? {
        let format = fileFormat(url, within: root)
        return format == .zipArchive ? nil : format
    }

    /// A ZIP archive opens as a window of its own and cannot join a binder.
    public static func isArchive(_ url: URL) -> Bool { fileFormat(url, within: nil) == .zipArchive }

    private static func fileFormat(_ url: URL, within root: String?) -> DocumentFormat? {
        guard url.isFileURL,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return nil }
        // The gate reads the beginning of the files whose name does not settle what they are: a `.ts` that is a
        // video is not a document, and a script with no extension is.
        switch TextFileGate.decide(url, within: root) {
        case .refused: return nil
        case .text: return .plainText
        case .unrelated:
            return DocumentFormat(fileExtension: url.pathExtension)
                ?? UTType(filenameExtension: url.pathExtension).flatMap { DocumentFormat(contentType: $0) }
        }
    }
}

/// The formats of the files of one request. Finding a format can mean reading the beginning of the file, so each
/// file is asked about once.
final class FileFormats {
    private var known: [URL: DocumentFormat?] = [:]

    func binderFormat(_ url: URL) -> DocumentFormat? {
        if let format = known[url] { return format }
        let format = OpenRequest.binderFormat(url)
        known[url] = .some(format)
        return format
    }
}
