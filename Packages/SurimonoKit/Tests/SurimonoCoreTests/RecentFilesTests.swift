import Foundation
import Testing

@testable import SurimonoCore

struct RecentFilesTests {
    @Test("最近開いたファイルが先頭になり重複は残らない")
    func ordering() {
        var history = RecentFiles(entries: [.init(path: "/a"), .init(path: "/b"), .init(path: "/a")])
        history.record(.init(path: "/b", bookmark: Data([1])), limit: 5)
        #expect(history.entries == [.init(path: "/b", bookmark: Data([1])), .init(path: "/a")])
    }

    @Test("システムと同じ上限で古いものを外し上限ゼロなら記録しない")
    func limit() {
        var history = RecentFiles(entries: [.init(path: "/a"), .init(path: "/b")])
        history.record(.init(path: "/c"), limit: 2)
        #expect(history.entries.map(\.path) == ["/c", "/a"])
        history.record(.init(path: "/d"), limit: 0)
        #expect(history.isEmpty)
    }

    @Test("ブックマークを作れなかった再登録は以前のデータを保つ")
    func bookmark() {
        var history = RecentFiles(entries: [.init(path: "/a", bookmark: Data([2]))])
        history.record(.init(path: "/a"), limit: 5)
        #expect(history.entries == [.init(path: "/a", bookmark: Data([2]))])
    }

    @Test("消去して保存し直すと空の一覧になる")
    func clear() throws {
        var history = RecentFiles(entries: [.init(path: "/a")])
        history.clear()
        let loaded = try JSONDecoder().decode(RecentFiles.self, from: JSONEncoder().encode(history))
        #expect(loaded.isEmpty)
    }

    @Test("保存値の重複と読めない項目を外して残りを復元する")
    func decode() throws {
        let data = Data(#"{"entries":[{"path":"/a"},{"bad":true},{"path":"/a"},{"path":"/b"}]}"#.utf8)
        let history = try JSONDecoder().decode(RecentFiles.self, from: data)
        #expect(history.entries.map(\.path) == ["/a", "/b"])
    }
}
