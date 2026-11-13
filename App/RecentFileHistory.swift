import AppKit
import ObjectiveC
import SurimonoCore

@MainActor
final class RecentFileHistory {
    static var shared: RecentFileHistory?
    let preferences: AppPreferences
    var systemURLs: () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }
    var systemLimit: () -> Int = { Int(NSDocumentController.shared.maximumRecentDocumentCount) }
    var noteSystemURL: (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }
    var locate: (RecentFile) -> URL? = { file in
        var stale = false
        #if APP_STORE
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        return file.bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: options, bookmarkDataIsStale: &stale)
        } ?? URL(fileURLWithPath: file.path)
    }
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    private var isRestoring = false

    init(preferences: AppPreferences) { self.preferences = preferences }

    func record(_ url: URL) {
        guard !isRestoring, url.isFileURL else { return }
        preferences.recentFiles.record(Self.entry(for: url), limit: systemLimit())
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

    var visibleURLs: [URL] {
        let system = systemURLs()
        return system.isEmpty ? preferences.recentFiles.entries.compactMap(locate) : system
    }

    static func install(preferences: AppPreferences) {
        shared = RecentFileHistory(preferences: preferences)
        _ = installHooks
    }

    // DocumentGroup owns its NSDocumentController subclass. Preserve it and intercept only the two public history
    // methods, including calls made by AppKit when opening a document from the standard Recent Items menu.
    private static let installHooks: Void = {
        for (original, replacement) in [
            (
                #selector(NSDocumentController.noteNewRecentDocumentURL(_:)),
                #selector(NSDocumentController.surimonoNoteRecent(_:))
            ),
            (
                #selector(NSDocumentController.clearRecentDocuments(_:)),
                #selector(NSDocumentController.surimonoClearRecent(_:))
            ),
        ] {
            if let originalMethod = class_getInstanceMethod(NSDocumentController.self, original),
                let replacementMethod = class_getInstanceMethod(NSDocumentController.self, replacement)
            {
                method_exchangeImplementations(originalMethod, replacementMethod)
            }
        }
    }()
}

extension NSDocumentController {
    @objc fileprivate dynamic func surimonoNoteRecent(_ url: URL) {
        surimonoNoteRecent(url)
        RecentFileHistory.shared?.record(url)
    }

    @objc fileprivate dynamic func surimonoClearRecent(_ sender: Any?) {
        surimonoClearRecent(sender)
        RecentFileHistory.shared?.clear()
    }
}
