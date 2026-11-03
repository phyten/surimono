import Darwin
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves a copy of a live page and the files under its document's directory, and nothing else from the disk. The
/// live page could read only its own directory; its copy on paper must not read more.
@MainActor
final class SnapshotSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "surimono-snapshot"
    static let rootURL: URL = {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "document"
        components.path = "/"
        return components.url ?? URL(fileURLWithPath: "/")
    }()
    /// A name no document file is likely to have; the copy is served under it at the root of the directory.
    static let pageURL = rootURL.appendingPathComponent("surimono-snapshot-page.html")
    /// Larger files, such as videos, are not worth holding in memory for a printout.
    nonisolated static let maximumFileSize = 50 * 1024 * 1024

    private var html = ""
    private var directory: URL?
    /// Tasks still waiting for their file; WebKit must not hear from a task it has stopped.
    private var runningTasks = Set<ObjectIdentifier>()

    func serve(_ html: String, directory: URL) {
        self.html = html
        self.directory = directory
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme, url.host == Self.rootURL.host, let directory
        else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        if url.path == Self.pageURL.path {
            // Only the copy is known to be UTF-8; it was made from a string.
            return Self.respond(to: task, url: url, data: Data(html.utf8), mimeType: "text/html", encoding: "utf-8")
        }
        let id = ObjectIdentifier(task as AnyObject)
        runningTasks.insert(id)
        let reading = Task.detached(priority: .userInitiated) {
            try? Self.readFile(for: url.path, in: directory)
        }
        let pending = PendingTask(task)
        Task { [weak self] in
            let data = await reading.value
            guard let self, runningTasks.remove(id) != nil else { return }
            guard let data else { return pending.task.didFailWithError(URLError(.cannotOpenFile)) }
            // Other files keep their own encoding, such as a Shift_JIS page in a frame.
            let mimeType =
                UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            Self.respond(to: pending.task, url: url, data: data, mimeType: mimeType, encoding: nil)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        runningTasks.remove(ObjectIdentifier(task as AnyObject))
    }

    private static func respond(
        to task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String, encoding: String?
    ) {
        task.didReceive(
            URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: encoding))
        task.didReceive(data)
        task.didFinish()
    }

    nonisolated static func readFile(
        for path: String, in directory: URL, maximumSize: Int = maximumFileSize,
        afterValidation: (() throws -> Void)? = nil
    ) throws -> Data {
        // Foundation may keep /var as an alias; compare against the canonical spelling used by F_GETPATH.
        let root = try directory.withUnsafeFileSystemRepresentation { path -> URL in
            guard let path, let resolved = Darwin.realpath(path, nil) else { throw posixError() }
            defer { Darwin.free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved))
        }
        guard maximumSize >= 0, maximumSize < Int.max, let file = fileURL(for: path, in: root) else {
            throw CocoaError(.fileReadNoPermission)
        }
        // Resolve legitimate in-directory links first; reject a new final symlink and never wait on a FIFO.
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &opened) == 0 else { throw posixError() }
        let actualPath = opened.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { String(validatingCString: $0) }
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let actualPath, actualPath.hasPrefix(prefix) else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumSize else {
            throw CocoaError(.fileReadNoPermission)
        }
        try afterValidation?()
        // The same descriptor survives path replacement; the read limit also covers growth after fstat.
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
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

    /// A regular file under the directory, small enough to serve; nil for anything else, so that a pipe or a device
    /// can never block the read.
    static func servableFile(for path: String, in directory: URL, maximumSize: Int = maximumFileSize) -> URL? {
        guard let file = fileURL(for: path, in: directory),
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, (values.fileSize ?? .max) <= maximumSize
        else { return nil }
        return file
    }

    /// The file a path of the scheme names, or nil when it would leave the directory, also through a symbolic link.
    nonisolated static func fileURL(for path: String, in directory: URL) -> URL? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let relative = String(path.drop { $0 == "/" })
        guard !relative.isEmpty else { return nil }
        let named = root.appendingPathComponent(relative).standardizedFileURL
        // Symbolic links are resolved only along a path that exists, so a missing file could hide a link that leads
        // out; only existing files are served anyway.
        guard FileManager.default.fileExists(atPath: named.path) else { return nil }
        let file = named.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }
}

/// Carries a scheme task across the file read. The task is only ever used on the main actor, where WebKit started it.
private struct PendingTask: @unchecked Sendable {
    let task: any WKURLSchemeTask
    init(_ task: any WKURLSchemeTask) { self.task = task }
}
