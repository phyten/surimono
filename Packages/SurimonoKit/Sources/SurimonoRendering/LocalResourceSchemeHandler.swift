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
        let documentPath = try? ConfinedFile.canonicalPath(access.documentURL)
        let roots = access.folders.compactMap { try? ConfinedFile.canonicalPath($0) }
        let descriptor = try ConfinedFile.open(named)
        defer { Darwin.close(descriptor) }
        let path = try ConfinedFile.openedPath(descriptor)
        guard
            path == documentPath
                || roots.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") })
        else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw ConfinedFile.posixError() }
        let maximumSize = 50 * 1024 * 1024
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumSize else {
            throw CocoaError(.fileReadNoPermission)
        }
        try afterValidation?()
        // The checked descriptor survives replacement of the file or any directory in its original path.
        let data = try ConfinedFile.readBytes(descriptor, size: Int(info.st_size), maximumSize: maximumSize)
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
