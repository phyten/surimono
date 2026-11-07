import SurimonoCore
import Testing

struct BinderNavigationTests {
    @Test("文書の境界と間の白紙は直前の文書に属する")
    func boundaries() {
        let starts = [0, 2, 6]
        #expect(BinderPagination.documentIndex(containing: 0, starts: starts, pageCount: 8) == 0)
        #expect(BinderPagination.documentIndex(containing: 1, starts: starts, pageCount: 8) == 0)
        #expect(BinderPagination.documentIndex(containing: 2, starts: starts, pageCount: 8) == 1)
        #expect(BinderPagination.documentIndex(containing: 5, starts: starts, pageCount: 8) == 1)
        #expect(BinderPagination.documentIndex(containing: 7, starts: starts, pageCount: 8) == 2)
        #expect(BinderPagination.documentIndex(containing: 8, starts: starts, pageCount: 8) == nil)
        #expect(BinderPagination.documentIndex(containing: -1, starts: starts, pageCount: 8) == nil)
        #expect(BinderPagination.documentIndex(containing: 0, starts: [], pageCount: 0) == nil)
    }

    @Test("見開きでは選んだ文書が見える間は保ち見えなくなれば先頭の文書へ移る")
    func followsVisiblePages() {
        #expect(BinderPagination.selection(current: 1, visiblePages: [1, 2], starts: [0, 2, 4], pageCount: 6) == 1)
        #expect(BinderPagination.selection(current: 0, visiblePages: [1, 2], starts: [0, 2, 4], pageCount: 6) == 0)
        #expect(BinderPagination.selection(current: 0, visiblePages: [3, 4], starts: [0, 2, 4], pageCount: 6) == 1)
        #expect(BinderPagination.selection(current: nil, visiblePages: [2], starts: [0, 2], pageCount: 4) == 1)
        #expect(BinderPagination.selection(current: 1, visiblePages: [], starts: [0, 2], pageCount: 4) == 1)
    }

    @Test("両面と冊子だけが両面に刷る")
    func bothSides() {
        #expect(!PrintLayout.a4Single.hasFacingPages)
        #expect(PrintLayout.a4Duplex.hasFacingPages)
        #expect(PrintLayout.a4BookletA5.hasFacingPages)
        #expect(!PrintLayout.a3TwoUp.hasFacingPages)
    }
}
