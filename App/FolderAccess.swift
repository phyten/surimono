import Foundation
import SurimonoCore

@MainActor
final class FolderAccess {
    struct Backend {
        var create: (URL) throws -> Data
        var resolve: (Data) throws -> (url: URL, stale: Bool)
        var start: (URL) -> Bool
        var stop: (URL) -> Void

        static let system = Backend(
            create: { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) },
            resolve: {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                    bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() })
    }

    final class Lease {
        let url: URL
        private var release: (() -> Void)?

        init(url: URL, release: @escaping () -> Void) {
            self.url = url
            self.release = release
        }

        func close() {
            release?()
            release = nil
        }
    }

    static let shared = FolderAccess()
    private let defaults: UserDefaults
    private let backend: Backend
    private let key = "ResourceFolderBookmarks"

    init(defaults: UserDefaults = .standard, backend: Backend = .system) {
        self.defaults = defaults
        self.backend = backend
    }

    func remember(_ folder: URL) throws {
        let started = backend.start(folder)
        defer { if started { backend.stop(folder) } }
        let data = try backend.create(folder)
        var records = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        records[folder.standardizedFileURL.path] = data
        defaults.set(records, forKey: key)
    }

    func acquire(for document: URL) -> Lease? {
        var records = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        defer { defaults.set(records, forKey: key) }
        var selected: (url: URL, path: String)?
        for (name, data) in records.sorted(by: { $0.key < $1.key }) {
            do {
                let resolved = try backend.resolve(data)
                guard backend.start(resolved.url) else {
                    records.removeValue(forKey: name)
                    continue
                }
                guard LocalResourceAccess.contains(document.deletingLastPathComponent(), in: resolved.url) else {
                    backend.stop(resolved.url)
                    continue
                }
                if resolved.stale {
                    do {
                        records[name] = try backend.create(resolved.url)
                    } catch {
                        backend.stop(resolved.url)
                        records.removeValue(forKey: name)
                        continue
                    }
                }
                // Bookmarks can move, so compare resolved roots rather than their saved dictionary keys.
                let path = resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
                if let current = selected, current.path.count <= path.count {
                    backend.stop(resolved.url)
                } else {
                    if let current = selected { backend.stop(current.url) }
                    selected = (resolved.url, path)
                }
            } catch {
                records.removeValue(forKey: name)
            }
        }
        guard let selected else { return nil }
        let stop = backend.stop
        return Lease(url: selected.url, release: { stop(selected.url) })
    }
}
