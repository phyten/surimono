import Darwin
import Foundation
import PDFKit
import SurimonoCore
import UniformTypeIdentifiers
import WebKit

@MainActor
public final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated public static let scheme = "surimono-local"
    public let access: LocalResourceAccess
    public private(set) var requiredFolderAccess: URL?
    public var onDenied: ((URL) -> Void)?
    private let html: String?
    private var runningTasks = Set<ObjectIdentifier>()

    public init(access: LocalResourceAccess, html: String? = nil) {
        self.access = access
        self.html = html
    }

    nonisolated public static func url(for file: URL) -> URL {
        var parts = URLComponents(url: file, resolvingAgainstBaseURL: true)
        parts?.scheme = scheme
        parts?.host = "document"
        return parts?.url ?? file
    }

    nonisolated public static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == "document", url.user == nil, url.password == nil, url.port == nil
        else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        parts?.scheme = "file"
        parts?.host = ""
        return parts?.url
    }

    // Exported PDFs must keep usable file links outside Surimono as well.
    static func restoreFileLinks(in document: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            restoreFileLinks(on: page)
        }
    }

    static func restoreFileLinks(on page: PDFPage) {
        for annotation in page.annotations {
            guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
                let file = fileURL(for: url)
            else { continue }
            annotation.url = file
        }
    }

    struct Resource: Sendable {
        let data: Data
        let mimeType: String
        let encoding: String?
    }

    func resource(at url: URL, afterValidation: (() throws -> Void)? = nil) throws -> Resource {
        do {
            return try Self.read(url, access: access, html: html, afterValidation: afterValidation)
        } catch {
            deny()
            throw error
        }
    }

    nonisolated private static func read(
        _ url: URL, access: LocalResourceAccess, html: String?, afterValidation: (() throws -> Void)? = nil
    ) throws -> Resource {
        guard let named = Self.fileURL(for: url) else { throw CocoaError(.fileReadNoPermission) }
        // Generated HTML is already in memory; serving it never opens a path supplied by the page.
        if let html, named.standardizedFileURL.path == access.documentURL.standardizedFileURL.path {
            return Resource(
                data: Data(LocalResourceURLRewriter.html(html).utf8), mimeType: "text/html", encoding: "utf-8")
        }
        let documentPath = try? canonicalPath(access.documentURL)
        let roots = access.folders.compactMap { try? canonicalPath($0) }
        // Nonblocking open lets fstat reject a FIFO without waiting for a writer.
        let descriptor = named.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        let path = try openedPath(descriptor)
        guard
            path == documentPath
                || roots.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") })
        else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError() }
        let maximumSize = 50 * 1024 * 1024
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumSize else {
            throw CocoaError(.fileReadNoPermission)
        }
        try afterValidation?()
        // The checked descriptor survives replacement of the file or any directory in its original path.
        let data = try readBytes(descriptor, size: Int(info.st_size), maximumSize: maximumSize)
        let file = URL(fileURLWithPath: path)
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if ["text/html", "text/css", "image/svg+xml"].contains(mime) {
            let decoded = TextDecoding.decode(data)
            return Resource(
                data: Data(
                    (mime == "text/css"
                        ? LocalResourceURLRewriter.css(decoded.text) : LocalResourceURLRewriter.html(decoded.text)).utf8
                ),
                mimeType: mime, encoding: "utf-8")
        }
        return Resource(data: data, mimeType: mime, encoding: nil)
    }

    nonisolated private static func canonicalPath(_ url: URL) throws -> String {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { throw posixError() }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
    }

    nonisolated private static func openedPath(_ descriptor: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &path) == 0 else { throw posixError() }
        return try path.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, let path = String(validatingCString: base) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return path
        }
    }

    nonisolated private static func readBytes(_ descriptor: Int32, size: Int, maximumSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // A file can grow after fstat, so enforce the limit while reading as well.
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumSize - data.count + 1))
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return data }
            guard count <= maximumSize - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    nonisolated private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func deny() {
        requiredFolderAccess = access.documentFolder
        onDenied?(access.documentFolder)
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let id = ObjectIdentifier(task as AnyObject)
        runningTasks.insert(id)
        let access = access
        let html = html
        let reading = Task.detached(priority: .userInitiated) { try Self.read(url, access: access, html: html) }
        let pending = PendingResourceTask(task: task)
        Task { [weak self] in
            let result = await reading.result
            guard let self, runningTasks.remove(id) != nil else { return }
            switch result {
            case .success(let resource):
                pending.task.didReceive(
                    URLResponse(
                        url: url, mimeType: resource.mimeType, expectedContentLength: resource.data.count,
                        textEncodingName: resource.encoding))
                pending.task.didReceive(resource.data)
                pending.task.didFinish()
            case .failure(let error):
                deny()
                pending.task.didFailWithError(error)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        runningTasks.remove(ObjectIdentifier(task as AnyObject))
    }
}

// WebKit's task is used only on the main actor, after the detached read has finished.
private struct PendingResourceTask: @unchecked Sendable {
    let task: any WKURLSchemeTask
}
