import Foundation
import SurimonoCore
import Testing

struct KeyedRecordStoreTests {
    private struct Record: Codable, Equatable {
        var value: Int
    }

    private func withStore(capacity: Int = 10, _ body: (KeyedRecordStore<Record>, URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(KeyedRecordStore<Record>(directory: directory, capacity: capacity), directory)
    }

    private func age(_ key: String, in directory: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)],
            ofItemAtPath: directory.appendingPathComponent("\(key).json").path)
    }

    @Test("保存したレコードをキーで読み戻せる")
    func saveAndLoad() throws {
        try withStore { store, _ in
            try store.save(Record(value: 1), for: "abc")
            #expect(store.record(for: "abc") == Record(value: 1))
            #expect(store.record(for: "missing") == nil)
        }
    }

    @Test("同じキーに保存すると上書きする")
    func overwrite() throws {
        try withStore { store, _ in
            try store.save(Record(value: 1), for: "abc")
            try store.save(Record(value: 2), for: "abc")
            #expect(store.record(for: "abc") == Record(value: 2))
            #expect(store.keys() == ["abc"])
        }
    }

    @Test("削除したレコードは読めず、ないキーの削除は何もしない")
    func remove() throws {
        try withStore { store, _ in
            try store.save(Record(value: 1), for: "abc")
            try store.removeRecord(for: "abc")
            try store.removeRecord(for: "abc")
            #expect(store.record(for: "abc") == nil)
        }
    }

    @Test("ファイル名にできないキーは拒否する", arguments: ["", "../etc", "a/b", "ABC", "名前", String(repeating: "a", count: 129)])
    func invalidKeys(_ key: String) throws {
        try withStore { store, directory in
            #expect(throws: KeyedRecordStore<Record>.StoreError.invalidKey) {
                try store.save(Record(value: 1), for: key)
            }
            #expect(store.record(for: key) == nil)
            let outside = directory.deletingLastPathComponent().appendingPathComponent("etc.json")
            #expect(!FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test("保存先の外を指すリンクは読まず、リンク先の更新日時も変えない")
    func symbolicLinkIsIgnored() throws {
        try withStore { store, directory in
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outside) }
            try JSONEncoder().encode(Record(value: 7)).write(to: outside)
            let past = Date(timeIntervalSince1970: 1_000_000_000)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: outside.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("abc.json"), withDestinationURL: outside)
            #expect(store.record(for: "abc") == nil)
            let modified = try FileManager.default.attributesOfItem(atPath: outside.path)[.modificationDate] as? Date
            #expect(modified == past)
        }
    }

    @Test("通常のファイルでない記録は待たずに nil として扱う", .timeLimit(.minutes(1)))
    func fifoIsIgnored() throws {
        try withStore { store, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(mkfifo(directory.appendingPathComponent("abc.json").path, 0o600) == 0)
            #expect(store.record(for: "abc") == nil)
        }
    }

    @Test("読めない JSON は nil として扱う")
    func corruptRecord() throws {
        try withStore { store, directory in
            try store.save(Record(value: 1), for: "abc")
            try Data("not json".utf8).write(to: directory.appendingPathComponent("abc.json"))
            #expect(store.record(for: "abc") == nil)
        }
    }

    @Test("上限を超えたら最も長く使っていないものから消す")
    func pruneLeastRecentlyUsed() throws {
        try withStore(capacity: 2) { store, directory in
            try store.save(Record(value: 1), for: "a")
            try store.save(Record(value: 2), for: "b")
            try age("a", in: directory, secondsAgo: 200)
            try age("b", in: directory, secondsAgo: 100)
            try store.save(Record(value: 3), for: "c")
            #expect(Set(store.keys()) == ["b", "c"])
        }
    }

    @Test("読んだレコードは最近使ったものとして残る")
    func readingMarksAsRecent() throws {
        try withStore(capacity: 2) { store, directory in
            try store.save(Record(value: 1), for: "a")
            try store.save(Record(value: 2), for: "b")
            try age("a", in: directory, secondsAgo: 200)
            try age("b", in: directory, secondsAgo: 100)
            _ = store.record(for: "a")
            try store.save(Record(value: 3), for: "c")
            #expect(Set(store.keys()) == ["a", "c"])
        }
    }
}
