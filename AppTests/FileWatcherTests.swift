import Foundation
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

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "5秒以内に変更が通知される")
    }
}
