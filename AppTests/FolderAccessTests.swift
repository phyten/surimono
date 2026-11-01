import Foundation
import Testing

@testable import Surimono

@MainActor
struct FolderAccessTests {
    @Test("フォルダ許可を保存し祖先のブックマークを解決して閉じると解放する")
    func ancestorAndLifetime() throws {
        let suite = "FolderAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        var stops = 0
        let backend = FolderAccess.Backend(
            create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { _ in
                starts += 1
                return true
            }, stop: { _ in stops += 1 })
        let folder = URL(fileURLWithPath: "/documents", isDirectory: true)
        try FolderAccess(defaults: defaults, backend: backend).remember(folder)
        let store = FolderAccess(defaults: defaults, backend: backend)
        let lease = try #require(store.acquire(for: folder.appending(path: "sub/report.md")))
        #expect(lease.url.path == folder.path)
        #expect(store.acquire(for: URL(fileURLWithPath: "/documents-other/report.md")) == nil)
        lease.close()
        lease.close()
        #expect(starts == stops)
    }

    @Test("古いブックマークは許可中に更新し解決できないものを捨てる")
    func staleBookmarks() throws {
        let suite = "FolderAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = URL(fileURLWithPath: "/documents", isDirectory: true)
        var creations = 0
        var fail = false
        let backend = FolderAccess.Backend(
            create: { _ in
                creations += 1
                return Data([UInt8(creations)])
            },
            resolve: { _ in
                if fail { throw CocoaError(.fileReadCorruptFile) }
                return (folder, true)
            }, start: { _ in true }, stop: { _ in })
        let store = FolderAccess(defaults: defaults, backend: backend)
        try store.remember(folder)
        let lease = try #require(store.acquire(for: folder.appending(path: "report.md")))
        #expect(creations == 2)
        lease.close()
        fail = true
        #expect(store.acquire(for: folder.appending(path: "report.md")) == nil)
        fail = false
        #expect(store.acquire(for: folder.appending(path: "report.md")) == nil)
    }
    @Test("古いブックマークの更新失敗は許可を解放して記録を捨てる")
    func failedRenewalReleasesAccess() throws {
        let suite = "FolderAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = URL(fileURLWithPath: "/documents", isDirectory: true)
        var fail = false
        var active = 0
        let backend = FolderAccess.Backend(
            create: { _ in
                if fail { throw CocoaError(.fileWriteNoPermission) }
                return Data([1])
            }, resolve: { _ in (folder, true) },
            start: { _ in
                active += 1
                return true
            }, stop: { _ in active -= 1 })
        let store = FolderAccess(defaults: defaults, backend: backend)
        try store.remember(folder)
        fail = true
        #expect(store.acquire(for: folder.appending(path: "report.md")) == nil)
        #expect(active == 0)
        fail = false
        #expect(store.acquire(for: folder.appending(path: "report.md")) == nil)
    }

    @Test("子のあと親を許可すると取り直しと新しいインスタンスの両方で親を選ぶ")
    func broaderGrantSurvivesReopening() throws {
        let suite = "FolderAccessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = 0
        let backend = FolderAccess.Backend(
            create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { _ in
                active += 1
                return true
            }, stop: { _ in active -= 1 })
        let parent = URL(fileURLWithPath: "/documents", isDirectory: true)
        let child = parent.appending(path: "sub", directoryHint: .isDirectory)
        let document = child.appending(path: "report.md")
        let store = FolderAccess(defaults: defaults, backend: backend)
        try store.remember(child)
        let initial = try #require(store.acquire(for: document))
        #expect(initial.url.path == child.path)
        initial.close()
        try store.remember(parent)
        for instance in [store, FolderAccess(defaults: defaults, backend: backend)] {
            let lease = try #require(instance.acquire(for: document))
            #expect(lease.url.path == parent.path)
            lease.close()
        }
        #expect(active == 0)
    }

}
