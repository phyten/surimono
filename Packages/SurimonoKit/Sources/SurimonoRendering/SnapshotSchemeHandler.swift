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
    static let maximumFileSize = 50 * 1024 * 1024

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
        guard let file = Self.servableFile(for: url.path, in: directory) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let id = ObjectIdentifier(task as AnyObject)
        runningTasks.insert(id)
        let reading = Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }
        let pending = PendingTask(task)
        Task { [weak self] in
            let data = await reading.value
            guard let self, runningTasks.remove(id) != nil else { return }
            guard let data else { return pending.task.didFailWithError(URLError(.cannotOpenFile)) }
            // Other files keep their own encoding, such as a Shift_JIS page in a frame.
            let mimeType =
                UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
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
    static func fileURL(for path: String, in directory: URL) -> URL? {
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
