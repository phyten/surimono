import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct FileWatcherTests {
    @Test("上書き保存とアトミック置換を通知し削除後の再作成も検出する", .timeLimit(.minutes(1)))
    func changes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.txt")
        try Data("first".utf8).write(to: url)
        var events: [FileWatcher.Event] = []
        let watcher = FileWatcher(url: url) { events.append($0) }
        defer { watcher.stop() }
        try await wait { watcher.isReady }
        #expect(events == [.check])
        events.removeAll()
        try Data("overwritten".utf8).write(to: url)
        try await wait { events.count == 1 }
        #expect(events.last == .changed)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        try await wait { events.count == 2 }
        #expect(events.last == .changed)
        try FileManager.default.removeItem(at: url)
        try await wait { events.count == 3 }
        #expect(events.last == .removed)
        try Data("restored".utf8).write(to: url)
        try await wait { events.count == 4 }
        #expect(events.last == .changed)
    }

    @Test("短い間隔の連続書き込みは静まってから一度だけ通知する", .timeLimit(.minutes(1)))
    func coalescesWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("initial".utf8).write(to: url)
        var events: [FileWatcher.Event] = []
        let watcher = FileWatcher(url: url) { events.append($0) }
        defer { watcher.stop() }
        try await wait { watcher.isReady }
        #expect(events == [.check])
        events.removeAll()
        for value in ["a", "ab", "abc"] {
            try Data(value.utf8).write(to: url)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(events.isEmpty)
        try await wait { events.count == 1 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(events == [.changed])
    }

    @Test("内容が同じtouchでは再組版せず内容変更では読んでいたページを保つ", .timeLimit(.minutes(1)))
    func unchangedContentDoesNotReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.md")
        let data = Data("original".utf8)
        try data.write(to: url)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        var paginations = 0
        let renderer = DocumentRenderer(paginate: { _ in
            paginations += 1
            return PDFDocument(data: TestFixtures.pdf("Preview", pages: 4))!
        })
        let model = DocumentViewModel(
            data: data, fileURL: url, format: .markdown, preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")), renderer: renderer,
            settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        model.start()
        defer { model.stop() }
        try await wait { model.result != nil && !model.isRendering }
        let original = try #require(model.result?.logicalDocument)
        let count = paginations
        model.currentPageIndex = 2
        // Observe the same metadata change independently, so the no-reload assertion is not a missed-event pass.
        var observed = false
        let observer = FileWatcher(url: url) { _ in observed = true }
        defer { observer.stop() }
        try await wait { observer.isReady }
        observed = false
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        try await wait { observed }
        try await Task.sleep(for: .milliseconds(500))
        #expect(paginations == count)
        #expect(model.result?.logicalDocument === original)
        try Data("changed".utf8).write(to: url, options: .atomic)
        try await wait { paginations > count && !model.isRendering }
        #expect(model.currentPageIndex == 2)
    }

    @Test(
        "初回と変更確認の途中で停止または解放すると遅れた通知を届けない", .timeLimit(.minutes(1)),
        arguments: [1, 3], [false, true])
    func cancelsDelivery(heldCheck: Int, releasesWatcher: Bool) async throws {
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        // Every access is protected by lock, including the detached polling task.
        nonisolated(unsafe) var checks = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("initial".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var events: [FileWatcher.Event] = []
        var watcher: FileWatcher? = FileWatcher(
            url: url,
            beforeCheck: {
                #expect(!Thread.isMainThread)
                let count = lock.withLock {
                    checks += 1
                    return checks
                }
                if count == heldCheck { release.wait() }
            },
            onChange: { events.append($0) })
        defer {
            watcher?.stop()
            release.signal()
        }
        if heldCheck > 1 {
            try await wait { watcher?.isReady == true }
            #expect(events == [.check])
            events.removeAll()
        }
        try Data("changed".utf8).write(to: url, options: .atomic)
        try await wait { lock.withLock { checks == heldCheck } }
        weak var released = watcher
        if releasesWatcher {
            watcher = nil
            #expect(released == nil)
        } else {
            watcher?.stop()
        }
        release.signal()
        try await Task.sleep(for: .milliseconds(600))
        #expect(events.isEmpty)
        #expect(lock.withLock { checks } == heldCheck)
    }

    @Test("初回の監視確認を待つ間の保存と削除を追加の保存なしで照合する", .timeLimit(.minutes(1)), arguments: [false, true])
    func reconcilesDelayedStart(deletes: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("loaded".utf8).write(to: url)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var events: [FileWatcher.Event] = []
        let watcher = FileWatcher(
            url: url,
            beforeCheck: {
                entered.signal()
                release.wait()
            },
            onChange: { events.append($0) })
        defer {
            watcher.stop()
            release.signal()
        }
        // Wait off-main; the UI remains available while the first filesystem check is held.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        if deletes {
            try FileManager.default.removeItem(at: url)
        } else {
            try Data("saved".utf8).write(to: url, options: .atomic)
        }
        release.signal()
        try await wait { watcher.isReady }
        #expect(events == [deletes ? .removed : .check])
    }

    @Test("監視の初回確認前に保存した内容を表示し削除なら最後の表示と通知を残す", .timeLimit(.minutes(1)), arguments: [false, true])
    func modelReconcilesDelayedStart(deletes: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.md")
        let loaded = Data("Original".utf8)
        try loaded.write(to: url)
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        var displayedHTML = ""
        let model = DocumentViewModel(
            data: loaded, fileURL: url, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: directory.appendingPathComponent("Library")),
            renderer: DocumentRenderer(paginate: { request in
                if case .html(let html, _) = request.source { displayedHTML = html }
                return PDFDocument(data: TestFixtures.pdf("Preview"))!
            }), settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        model.beforeWatcherCheck = {
            entered.signal()
            release.wait()
        }
        model.start()
        defer {
            model.stop()
            release.signal()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        try await wait { model.result != nil && !model.isRendering }
        if deletes {
            try FileManager.default.removeItem(at: url)
        } else {
            try Data("Saved before first poll".utf8).write(to: url, options: .atomic)
        }
        release.signal()
        if deletes {
            try await wait {
                model.toast?.title == String(localized: "The file is missing. The last preview is still available.")
            }
            #expect(displayedHTML.contains("Original"))
            #expect(model.canOutput)
        } else {
            try await wait { displayedHTML.contains("Saved before first poll") && !model.isRendering }
            #expect(model.canOutput)
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "5秒以内に変更が通知される")
    }
}
