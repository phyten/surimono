import Foundation
import Testing

@testable import SurimonoCore

struct BookmarksTests {
    @Test("見開きの両方を外し、次と前は端で止まる")
    func spreads() {
        var marks = Bookmarks()
        #expect(marks.isEmpty)
        for page in [10, 3, 4] {
            let added = marks.toggle(page: page, visiblePages: [page], pageCount: 20, entries: [])
            #expect(added)
        }
        #expect(marks.pages(pageCount: 20, entries: []) == [3, 4, 10])
        #expect(marks.next(after: 4, pageCount: 20, entries: []) == 10)
        #expect(marks.previous(before: 4, pageCount: 20, entries: []) == 3)
        #expect(marks.next(after: 10, pageCount: 20, entries: []) == nil)
        #expect(marks.previous(before: 3, pageCount: 20, entries: []) == nil)
        let removed = !marks.toggle(page: 3, visiblePages: [3, 4], pageCount: 20, entries: [])
        #expect(removed)
        #expect(marks.pages(pageCount: 20, entries: []) == [10])
        marks.remove(page: 10, pageCount: 20, entries: [])
        #expect(marks.isEmpty)
    }

    @Test("99個まで保存でき、ページのない文書には足さない")
    func limit() {
        var marks = Bookmarks()
        let ignoredEmptyDocument = !marks.toggle(page: 0, visiblePages: [], pageCount: 0, entries: [])
        #expect(ignoredEmptyDocument)
        for page in 0..<99 {
            let added = marks.toggle(page: page, visiblePages: [page], pageCount: 101, entries: [])
            #expect(added)
        }
        let refused = !marks.toggle(page: 99, visiblePages: [99], pageCount: 101, entries: [])
        #expect(refused)
        #expect(marks.pages(pageCount: 101, entries: []).count == 99)
    }

    @Test("組み直した位置を返し、同じページに重なる印は一行になる")
    func reflow() {
        var marks = Bookmarks()
        for page in [4, 5] { marks.toggle(page: page, visiblePages: [page], pageCount: 11, entries: []) }
        #expect(marks.pages(pageCount: 21, entries: []) == [8, 10])
        #expect(marks.pages(pageCount: 2, entries: []) == [0, 1])
        #expect(marks.pages(pageCount: 1, entries: []) == [0])
        #expect(marks.pages(pageCount: 0, entries: []).isEmpty)
    }

    @Test("章の前のページ数が変わっても章の中の位置を保つ")
    func chapterReflow() {
        var marks = Bookmarks()
        let before = [OutlineEntry(level: 1, title: "Chapter", pageIndex: 10)]
        let after = [OutlineEntry(level: 1, title: "Chapter", pageIndex: 30)]
        marks.toggle(page: 15, visiblePages: [15], pageCount: 30, entries: before)
        #expect(marks.pages(pageCount: 50, entries: after) == [35])
    }

    @Test("保存形式を固定し、未知のキーと壊れた要素を読み飛ばす")
    func persistence() throws {
        let json = #"{"positions":[{"fraction":0.5,"future":true},null,{"fraction":"bad"},{"fraction":1}],"future":42}"#
        let marks = try JSONDecoder().decode(Bookmarks.self, from: Data(json.utf8))
        #expect(marks.pages(pageCount: 11, entries: []) == [5, 10])
        let encoded = try JSONEncoder().encode(marks)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        let expected =
            try JSONSerialization.jsonObject(
                with: Data(#"{"positions":[{"fraction":0.5},{"fraction":1}]}"#.utf8)) as? NSDictionary
        #expect(object == expected)
        let positionJSON =
            #"{"fraction":0.5,"anchor":{"title":"Chapter","level":1,"occurrence":0,"offset":5,"length":11},"unknown":0}"#
        let position = try JSONDecoder().decode(ReadingPosition.self, from: Data(positionJSON.utf8))
        let positionObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(position)) as? NSDictionary
        let expectedPosition =
            try JSONSerialization.jsonObject(
                with: Data(
                    #"{"fraction":0.5,"anchor":{"title":"Chapter","level":1,"occurrence":0,"offset":5,"length":11}}"#
                        .utf8)) as? NSDictionary
        #expect(positionObject == expectedPosition)
        let generated = ReadingPosition(
            page: 5, pageCount: 11, entries: [OutlineEntry(level: 1, title: "Chapter", pageIndex: 0)])
        #expect(generated == position)
    }

    @Test("文書の古い記録を読み、空のしおりは書かず、しおりを往復する")
    func settings() throws {
        let old = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"zoom":2}"#.utf8))
        #expect(old.bookmarks == nil)
        var settings = DocumentSettings(bookmarks: Bookmarks())
        let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(empty?["bookmarks"] == nil)
        var marks = Bookmarks()
        marks.toggle(page: 5, visiblePages: [5], pageCount: 11, entries: [])
        settings.bookmarks = marks
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}
