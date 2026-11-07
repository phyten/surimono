import Foundation
import SurimonoCore
import Testing

struct RecentBindersTests {
    private func binder(_ names: String..., bookmark: Data? = nil) -> RecentBinder {
        RecentBinder(files: names.map { RecentBinder.File(path: "/docs/" + $0, bookmark: bookmark) })
    }

    private func paths(_ recent: RecentBinders) -> [[String]] {
        recent.entries.map(\.paths)
    }

    @Test("最近の合本は最大5件で、新しく閉じた合本が先頭に来る")
    func newestFirst() {
        var recent = RecentBinders()
        #expect(recent.isEmpty)
        recent.record(binder("a.md", "b.md"))
        recent.record(binder("c.md", "d.md"))
        #expect(paths(recent) == [["/docs/c.md", "/docs/d.md"], ["/docs/a.md", "/docs/b.md"]])
        #expect(RecentBinders.limit == 5)
    }

    @Test("6件目を足すと一番古い合本が落ちて5件に収まる")
    func dropsTheOldestPastTheLimit() {
        var recent = RecentBinders()
        for number in 1...6 { recent.record(binder("\(number).md", "x.md")) }
        #expect(
            recent.entries.map { $0.paths[0] }
                == ["/docs/6.md", "/docs/5.md", "/docs/4.md", "/docs/3.md", "/docs/2.md"])
    }

    @Test("同じファイルの組は順序が違っても1件にまとまり、新しい並びで先頭へ移る")
    func sameFilesAreOneBinder() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md"))
        recent.record(binder("c.md", "d.md"))
        recent.record(binder("b.md", "a.md"))
        #expect(paths(recent) == [["/docs/b.md", "/docs/a.md"], ["/docs/c.md", "/docs/d.md"]])
    }

    @Test("同じ組をまとめるときは新しい方のブックマークを残す")
    func newerBookmarkReplacesTheOlder() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md", bookmark: Data([1])))
        recent.record(binder("b.md", "a.md", bookmark: Data([2])))
        #expect(recent.entries.count == 1)
        #expect(recent.entries[0].files.map(\.bookmark) == [Data([2]), Data([2])])
    }

    @Test("ファイルの一部が重なるだけの組は別の合本として残る")
    func overlappingFilesAreDifferentBinders() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md"))
        recent.record(binder("a.md", "b.md", "c.md"))
        #expect(recent.entries.count == 2)
    }

    @Test("ファイルが1つだけの組は合本ではないので覚えない")
    func oneFileIsNotABinder() {
        var recent = RecentBinders()
        recent.record(binder("a.md"))
        recent.record(binder())
        #expect(recent.isEmpty)
    }

    @Test("同じパスが重なっていれば1つにして数え、並びは先に出た順を保つ")
    func repeatedPathsCountOnce() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "a.md"))
        #expect(recent.isEmpty)
        recent.record(binder("b.md", "a.md", "b.md"))
        #expect(paths(recent) == [["/docs/b.md", "/docs/a.md"]])
    }

    @Test("消去すると空になり、そのあとまた覚えられる")
    func clearing() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md"))
        recent.clear()
        #expect(recent.isEmpty)
        recent.record(binder("c.md", "d.md"))
        #expect(paths(recent) == [["/docs/c.md", "/docs/d.md"]])
    }

    @Test("合本の名前に使うのは先頭のファイル名で、同じ組は順序によらず同じ識別子になる")
    func nameAndIdentity() {
        #expect(binder("b.md", "a.md").firstName == "b.md")
        #expect(binder("b.md", "a.md").id == binder("a.md", "b.md").id)
        #expect(binder("a.md", "b.md").id != binder("a.md", "c.md").id)
        #expect(RecentBinder(files: []).firstName == "")
    }

    @Test("保存した値は、ブックマークのあるファイルもないファイルも、そのまま読み戻せる")
    func roundTrip() throws {
        var recent = RecentBinders()
        recent.record(
            RecentBinder(files: [
                RecentBinder.File(path: "/docs/a.md", bookmark: Data([0, 1, 2, 255])),
                RecentBinder.File(path: "/docs/b.md"),
            ]))
        recent.record(binder("c.md", "d.md"))
        let stored = try JSONEncoder().encode(recent)
        let restored = try JSONDecoder().decode(RecentBinders.self, from: stored)
        #expect(restored == recent)
        #expect(restored.entries[1].files[0].bookmark == Data([0, 1, 2, 255]))
        #expect(restored.entries[1].files[1].bookmark == nil)
    }

    @Test("読めない項目と合本でない項目だけを除いて読み戻す")
    func decodesWhatIsReadable() throws {
        let stored = Data(
            #"""
            {"entries": [
              {"files": [{"path": "/docs/a.md"}, {"path": "/docs/b.md"}]},
              {"files": "壊れた値"},
              {"files": [{"path": "/docs/c.md"}]},
              {"files": [{"path": "/docs/d.md"}, {"path": "/docs/e.md"}]}
            ]}
            """#.utf8)
        let restored = try JSONDecoder().decode(RecentBinders.self, from: stored)
        #expect(paths(restored) == [["/docs/a.md", "/docs/b.md"], ["/docs/d.md", "/docs/e.md"]])
    }

    @Test("5件を超えて保存された値と、同じ組が重なる値は、新しい側の5件と1件に整える")
    func decodeKeepsTheRules() throws {
        var entries: [RecentBinder] = []
        for number in 1...7 { entries.append(binder("\(number).md", "x.md")) }
        entries.insert(binder("x.md", "1.md"), at: 3)
        let stored = try JSONEncoder().encode(["entries": entries])
        let restored = try JSONDecoder().decode(RecentBinders.self, from: stored)
        #expect(
            restored.entries.map { $0.paths[0] }
                == ["/docs/1.md", "/docs/2.md", "/docs/3.md", "/docs/4.md", "/docs/5.md"])
        #expect(restored.entries.allSatisfy { $0.paths.count == 2 })
    }

    @Test("entriesがない値は読めない")
    func missingEntriesFail() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecentBinders.self, from: Data("{}".utf8))
        }
    }

    @Test("閉じるときにブックマークを作れなかったファイルは、同じパスの項目のブックマークを残す")
    func recordKeepsABookmarkItCouldNotMake() {
        var recent = RecentBinders()
        recent.record(
            RecentBinder(files: [
                .init(path: "/docs/a.md", bookmark: Data([1])), .init(path: "/docs/b.md", bookmark: Data([2])),
            ]))
        recent.record(RecentBinder(files: [.init(path: "/docs/a.md"), .init(path: "/docs/b.md", bookmark: Data([3]))]))
        #expect(recent.entries.count == 1)
        #expect(recent.entries[0].files.map(\.bookmark) == [Data([1]), Data([3])])
    }

    @Test("ファイルの動いた合本は、同じ位置で新しいパスの組に置き換わる")
    func replaceKeepsThePlace() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md"))
        recent.record(binder("c.md", "d.md"))
        recent.replace(binder("b.md", "a.md"), with: binder("moved.md", "b.md"))
        #expect(recent.entries.map(\.paths) == [["/docs/c.md", "/docs/d.md"], ["/docs/moved.md", "/docs/b.md"]])
    }

    @Test("置き換えた先の組がすでにあれば1件にまとまり、覚えていない組の置き換えは何も変えない")
    func replaceFollowsTheRules() {
        var recent = RecentBinders()
        recent.record(binder("a.md", "b.md"))
        recent.record(binder("c.md", "d.md"))
        recent.replace(binder("a.md", "b.md"), with: binder("d.md", "c.md"))
        #expect(recent.entries.map(\.paths) == [["/docs/c.md", "/docs/d.md"]])
        recent.replace(binder("x.md", "y.md"), with: binder("a.md", "b.md"))
        #expect(recent.entries.map(\.paths) == [["/docs/c.md", "/docs/d.md"]])
    }
}
