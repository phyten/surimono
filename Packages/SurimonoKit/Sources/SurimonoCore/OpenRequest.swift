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
    package init(urls: [URL], formats: FileFormats) {
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

    /// Keep the worker's decisions with the binder so creating its window does not inspect the files again.
    public static func plan(_ urls: [URL]) -> (request: Self, binderFormats: [URL: DocumentFormat]) {
        let formats = FileFormats()
        let request = Self(urls: urls, formats: formats)
        guard case .binder(let children, _) = request else { return (request, [:]) }
        var resolved: [URL: DocumentFormat] = [:]
        for url in children { resolved[url] = formats.binderFormat(url) }
        return (request, resolved)
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
        let format = fileFormat(url, within: root).format
        return format == .zipArchive ? nil : format
    }

    /// A ZIP archive opens as a window of its own and cannot join a binder.
    public static func isArchive(_ url: URL) -> Bool { fileFormat(url, within: nil).format == .zipArchive }

    /// What is known of a file's format, ZIP archives included.
    struct FileFormat {
        var format: DocumentFormat?
        /// The file could not be read yet, so `format` is what it would be if it turns out to be text.
        var isUndecided = false
    }

    static func fileFormat(
        _ url: URL, within root: String?, keepsUndecided: Bool = true,
        inspect: (URL, String?) -> TextFileGate.FileVerdict = { TextFileGate.inspect($0, within: $1) }
    ) -> FileFormat {
        guard url.isFileURL,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return FileFormat() }
        func named() -> DocumentFormat? {
            DocumentFormat(fileExtension: url.pathExtension)
                ?? UTType(filenameExtension: url.pathExtension).flatMap { DocumentFormat(contentType: $0) }
        }
        // The gate reads the beginning of the files whose name does not settle what they are: a `.ts` that is a
        // video is not a document, and a script with no extension is.
        switch inspect(url, root) {
        case .refused, .decided(.binary): return FileFormat()
        case .decided(.text): return FileFormat(format: .plainText)
        case .decided(.notConcerned), .missing: return FileFormat(format: named())
        // Before a sandboxed app is given the file there is nothing to read. It stays a candidate, and is decided
        // at the drop or when the folder is allowed.
        case .undecided:
            // Once the files have been given, one that still cannot be read is no candidate any more.
            return FileFormat(format: keepsUndecided ? named() ?? .plainText : nil, isUndecided: true)
        }
    }
}

/// The formats of the files of one request. Finding a format can mean reading the beginning of the file, so each
/// file is asked about once, for everything the request wants to know of it.
package final class FileFormats {
    private var known: [URL: OpenRequest.FileFormat] = [:]
    private let inspect: (URL, String?) -> TextFileGate.FileVerdict
    private let keepsUndecided: Bool

    /// `keepsUndecided` is false for a request that is carried out: what cannot be read by then is left out.
    package init(
        keepsUndecided: Bool = true,
        inspect: @escaping (URL, String?) -> TextFileGate.FileVerdict = { TextFileGate.inspect($0, within: $1) }
    ) {
        self.keepsUndecided = keepsUndecided
        self.inspect = inspect
    }

    private func format(_ url: URL) -> OpenRequest.FileFormat {
        if let format = known[url] { return format }
        let format = OpenRequest.fileFormat(url, within: nil, keepsUndecided: keepsUndecided, inspect: inspect)
        known[url] = format
        return format
    }

    package func binderFormat(_ url: URL) -> DocumentFormat? {
        let format = format(url).format
        return format == .zipArchive ? nil : format
    }

    package func isArchive(_ url: URL) -> Bool { format(url).format == .zipArchive }

    package func isUndecided(_ url: URL) -> Bool { format(url).isUndecided }
}
