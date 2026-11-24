import AppKit
import SurimonoCore

@MainActor
final class RecentFileHistory {
    static let systemListChanged = Notification.Name("SurimonoRecentDocumentsChanged")
    static var shared: RecentFileHistory?
    let preferences: AppPreferences
    var systemURLs: () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }
    var systemLimit: () -> Int = { Int(NSDocumentController.shared.maximumRecentDocumentCount) }
    var noteSystemURL: (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
    var locate: (RecentFile) -> URL? = { file in
        file.bookmark.flatMap(RecentFileHistory.resolve) ?? URL(fileURLWithPath: file.path)
    }

    nonisolated private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        #if APP_STORE
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        return try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
    }
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    private var isRestoring = false

    init(preferences: AppPreferences) { self.preferences = preferences }

    func record(_ url: URL) {
        guard !isRestoring, url.isFileURL, !GettingStarted.isInsideApp(url) else { return }
        preferences.recentFiles.record(Self.entry(for: url), limit: systemLimit())
    }

    /// A URL from the system list can have the right path but no sandbox extension after relaunch.
    /// Resolve just the chosen entry, preserving a URL granted by the system if its bookmark expired.
    func urlForOpening(_ url: URL) -> URL {
        guard let file = preferences.recentFiles.entries.first(where: { $0.path == url.standardizedFileURL.path }),
            let bookmark = file.bookmark
        else { return url }
        return Self.resolve(bookmark) ?? url
    }

    func clear() { preferences.recentFiles.clear() }

    private static func entry(for url: URL) -> RecentFile {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        #if APP_STORE
            let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
            let options: URL.BookmarkCreationOptions = []
        #endif
        return RecentFile(path: url.standardizedFileURL.path, bookmark: try? url.bookmarkData(options: options))
    }

    func restoreOnLaunch() {
        let system = systemURLs()
        if !system.isEmpty {
            // Seed existing installations while the system still knows their history, without changing its order.
            for url in system.reversed() { record(url) }
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        var surviving: [RecentFile] = []
        for file in preferences.recentFiles.entries {
            guard let url = locate(file) else { continue }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            guard exists(url) else { continue }
            var entry = Self.entry(for: url)
            entry.bookmark = entry.bookmark ?? file.bookmark
            surviving.append(entry)
        }
        var history = RecentFiles(entries: surviving)
        history.trim(to: systemLimit())
        preferences.recentFiles = history
        for file in history.entries.reversed() {
            guard let url = locate(file) else { continue }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            noteSystemURL(url)
        }
    }

    static var welcomeURLs: [URL] {
        #if DEBUG
            // snapshot-capability: empty-welcome. A regression artifact must never include filenames from the developer's system history.
            let snapshotWelcomeIsEmpty =
                DebugSnapshot.flag("SurimonoSnapshotWelcome")
                && DebugSnapshot.argument("SurimonoRunToken") != nil
            if snapshotWelcomeIsEmpty { return [] }
        #endif
        return shared?.visibleURLs ?? NSDocumentController.shared.recentDocumentURLs
    }

    var visibleURLs: [URL] {
        let system = systemURLs()
        return system.isEmpty ? preferences.recentFiles.entries.compactMap(locate) : system
    }

    static func install(preferences: AppPreferences) {
        shared = RecentFileHistory(preferences: preferences)
    }
}
