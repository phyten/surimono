import Testing

@testable import SurimonoCore

struct PageHistoryTests {
    private func position(_ page: Int) -> ReadingPosition {
        ReadingPosition(page: page, pageCount: 100, entries: [])
    }

    @Test("飛ぶ前へ戻り、進むと読み進めた場所へ戻る")
    func roundTrip() {
        var history = PageHistory()
        #expect(!history.canGoBack && !history.canGoForward)
        history.record(position(10))
        #expect(history.back(from: position(53)) == position(10))
        #expect(history.forward(from: position(10)) == position(53))
        #expect(history.forward(from: position(53)) == nil)
    }

    @Test("同じ位置を続けて積まず、新しい移動で進む側を消す")
    func duplicatesAndBranch() {
        var history = PageHistory()
        history.record(position(10))
        history.record(position(10))
        #expect(history.back(from: position(50)) == position(10))
        #expect(!history.canGoBack)
        history.record(position(10))
        #expect(!history.canGoForward)
    }

    @Test("戻る側は新しい50件を残す")
    func limit() {
        var history = PageHistory()
        for page in 0..<60 { history.record(position(page)) }
        for page in (10..<60).reversed() {
            #expect(history.back(from: position(page + 1)) == position(page))
        }
        #expect(history.back(from: position(10)) == nil)
    }
}
