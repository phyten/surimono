import AppKit
import SurimonoCore

/// How a recent binder keeps its files and finds them again. Outside the sandbox a path is enough. Inside it, access to
/// a file the reader chose ends when the app quits, so each file also keeps a read-only security-scoped bookmark, as a
/// folder does in `FolderAccess`.
struct RecentBinderFiles {
    var backend: FolderAccess.Backend = .system
    var isSandboxed: () -> Bool = { SandboxEnvironment.isSandboxed }

    /// The files of a binder that is closing. A file whose bookmark cannot be made keeps its path alone.
    func binder(of urls: [URL]) -> RecentBinder {
        let sandboxed = isSandboxed()
        return RecentBinder(
            files: urls.map { RecentBinder.File(path: $0.path, bookmark: sandboxed ? bookmark(of: $0) : nil) })
    }

    private func bookmark(of url: URL) -> Data? {
        // The window gave up its own access to the files as it closed, so take it again to make the bookmark.
        let started = backend.start(url)
        defer { if started { backend.stop(url) } }
        return try? backend.create(url)
    }

    /// What opens a recent binder.
    struct Located {
        let urls: [URL]
        /// The binder as it is now, with the paths of the files that have moved.
        let binder: RecentBinder
        /// The access taken to read the files.
        let leases: [FolderAccess.Lease]

        /// Holds the access until `window` closes, which is when the binder stops reading its files. Without a window
        /// there is nothing to hold it for.
        func keep(until window: NSWindow?) {
            guard let window, !leases.isEmpty else {
                for lease in leases { lease.close() }
                return
            }
            @MainActor final class Observation { var token: (any NSObjectProtocol)? }
            let observation = Observation()
            let leases = leases
            observation.token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { _ in
                // A turn later, because the closing window still makes the bookmarks of its files, which needs the access.
                Task { @MainActor in
                    for lease in leases { lease.close() }
                    if let token = observation.token { NotificationCenter.default.removeObserver(token) }
                    observation.token = nil
                }
            }
        }
    }

    /// Where the files of `binder` are now. A file that has moved is found by its bookmark; one that is gone is left to
    /// its path, and the binder shows it as unreadable.
    func locate(_ binder: RecentBinder) -> Located {
        let sandboxed = isSandboxed()
        var urls: [URL] = []
        var files: [RecentBinder.File] = []
        var leases: [FolderAccess.Lease] = []
        for file in binder.files {
            guard sandboxed, let data = file.bookmark, let resolved = try? backend.resolve(data) else {
                urls.append(URL(fileURLWithPath: file.path))
                files.append(file)
                continue
            }
            urls.append(resolved.url)
            files.append(RecentBinder.File(path: resolved.url.path, bookmark: data))
            if backend.start(resolved.url) {
                let stop = backend.stop
                leases.append(FolderAccess.Lease(url: resolved.url, release: { stop(resolved.url) }))
            }
        }
        return Located(urls: urls, binder: RecentBinder(files: files), leases: leases)
    }
}
