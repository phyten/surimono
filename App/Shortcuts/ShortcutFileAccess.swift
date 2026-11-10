import Foundation

/// Access to the files Shortcuts hands over. In the sandboxed build a file the app was never given arrives as a
/// security-scoped URL, which can be read only between a start and its stop.
final class ShortcutFileAccess {
    struct Backend {
        var start: (URL) -> Bool
        var stop: (URL) -> Void

        static let system = Backend(
            start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() })
    }

    static let shared = ShortcutFileAccess()
    private let backend: Backend

    init(backend: Backend = .system) {
        self.backend = backend
    }

    /// Reads for as long as `work` runs, however it ends.
    func reading<Value>(_ url: URL?, _ work: () async throws -> Value) async rethrows -> Value {
        let started = url.flatMap { backend.start($0) ? $0 : nil }
        defer { if let started { backend.stop(started) } }
        return try await work()
    }

    /// Access that lasts until each lease is closed, for windows that go on reading their files: they read again
    /// when a file changes. Whoever takes a lease closes it, as a binder does with its documents' access.
    func leases(for urls: [URL]) -> [FolderAccess.Lease] {
        let backend = backend
        return urls.filter { backend.start($0) }.map { url in
            FolderAccess.Lease(url: url) { backend.stop(url) }
        }
    }
}
