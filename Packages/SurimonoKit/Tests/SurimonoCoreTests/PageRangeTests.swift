import Foundation
import SurimonoCore
import Testing

struct PageRangeTests {
    @Test("1 つの範囲は始めと終わりのページを含む")
    func singleSpan() throws {
        #expect(try PageRange(parsing: "5-12").spans == [5...12])
    }

    @Test("番号と範囲を読点で並べられる")
    func list() throws {
        #expect(try PageRange(parsing: "1,3,7-9").spans == [1...1, 3...3, 7...9])
    }

    @Test("範囲の記号は - – 〜 ~ のどれでもよい", arguments: ["5-12", "5–12", "5〜12", "5~12", "5～12", "5－12"])
    func rangeMarks(text: String) throws {
        #expect(try PageRange(parsing: text).spans == [5...12])
    }

    @Test("区切りは , 、 空白のどれでもよい", arguments: ["1,3", "1、3", "1 3", "1，3", "1, 3", " 1　3 "])
    func separators(text: String) throws {
        #expect(try PageRange(parsing: text).spans == [1...1, 3...3])
    }

    @Test("全角の数字も読む")
    func fullWidthDigits() throws {
        #expect(try PageRange(parsing: "５〜１２、２０").spans == [5...12, 20...20])
    }

    @Test("記号の前後の空白は範囲を分けない")
    func spacesAroundMark() throws {
        #expect(try PageRange(parsing: "5 - 12").spans == [5...12])
    }

    @Test("空と All と「すべて」は全ページになる", arguments: ["", "  ", "All", "all", "すべて"])
    func everything(text: String) throws {
        #expect(try PageRange(parsing: text).isAll)
    }

    @Test("渡した言語の「すべて」も全ページになる")
    func localizedAll() throws {
        #expect(try PageRange(parsing: "Alle", allWords: ["Alle"]).isAll)
    }

    @Test("終わりを省くと最後のページまで、始めを省くと最初のページからになる")
    func openEnds() throws {
        #expect(try PageRange(parsing: "5-").spans == [5...PageRange.lastPage])
        #expect(try PageRange(parsing: "-5").spans == [1...5])
    }

    @Test("重なる範囲と隣り合う範囲はまとめ、順に並べる")
    func normalizes() throws {
        #expect(try PageRange(parsing: "7-9, 1-3, 2-4, 5").spans == [1...5, 7...9])
    }

    @Test(
        "読めない指定はエラーになる",
        arguments: [
            "abc", "9-7", "0", "0-3", "-", "1-a", "1.5", "p3", ",", "5--12", "1-3-5", "5 - - 12", "5-–12", "-5-", "--5",
            "5--", "１〜３〜５", "1-3 -5",
        ])
    func unreadable(text: String) {
        #expect(throws: PageRange.ParseError.unreadable) { try PageRange(parsing: text) }
    }

    @Test("終わりを省いた範囲は、区切りか文字の終わりが続くときだけ読む")
    func openEndNeedsSeparator() throws {
        #expect(try PageRange(parsing: "2, 5-").spans == [2...2, 5...PageRange.lastPage])
        #expect(try PageRange(parsing: "5-, 2").spans == [2...2, 5...PageRange.lastPage])
        #expect(try PageRange(parsing: "-3, 7").spans == [1...3, 7...7])
        #expect(try PageRange(parsing: "5 -").spans == [5...PageRange.lastPage])
    }

    @Test("記号の後ろの空白のあとに番号が続けば、1 つの範囲として読む")
    func spaceAfterMark() throws {
        #expect(try PageRange(parsing: "5- 12").spans == [5...12])
        #expect(try PageRange(parsing: "５ 〜 １２").spans == [5...12])
    }

    @Test("打っている途中の末尾の読点は無視する")
    func trailingComma() throws {
        #expect(try PageRange(parsing: "1,3,").spans == [1...1, 3...3])
    }

    @Test("表示の文字は番号と範囲を読点で並べ、全ページは空になる")
    func text() {
        #expect(PageRange([1...5, 8...8]).text == "1-5, 8")
        #expect(PageRange([5...PageRange.lastPage]).text == "5-")
        #expect(PageRange.all.text == "")
    }

    @Test("38 ページの文書の 5-12 は 5 ページ目から 12 ページ目を選ぶ")
    func selection() {
        let selection = PageRange([5...12]).selection(pageCount: 38)
        #expect(selection.pages == [4, 5, 6, 7, 8, 9, 10, 11])
        #expect(!selection.isOutOfDocument)
    }

    @Test("文書より後ろの番号は切り捨てる")
    func clamps() {
        #expect(PageRange([5...100]).selection(pageCount: 8).pages == [4, 5, 6, 7])
        #expect(PageRange([2...2, 30...40]).selection(pageCount: 8).pages == [1])
        #expect(PageRange([6...PageRange.lastPage]).selection(pageCount: 8).pages == [5, 6, 7])
    }

    @Test("文書にないページだけの指定は全ページを選び、ないことを伝える")
    func outOfDocument() {
        let selection = PageRange([40...50]).selection(pageCount: 38)
        #expect(selection.pages == nil)
        #expect(selection.isOutOfDocument)
    }

    @Test("全ページを覆う指定と指定なしは、どちらも全ページとして同じになる")
    func coveringEverything() {
        #expect(PageRange([1...8]).selection(pageCount: 8) == .everything)
        #expect(PageRange.all.selection(pageCount: 8) == .everything)
    }

    @Test("JSON には表示の文字で書き、読み戻せる")
    func codable() throws {
        let data = try JSONEncoder().encode([PageRange([1...5, 8...8])])
        #expect(String(decoding: data, as: UTF8.self) == #"["1-5, 8"]"#)
        #expect(try JSONDecoder().decode([PageRange].self, from: data) == [PageRange([1...5, 8...8])])
    }
}

struct PageRangeImpositionTests {
    @Test("38 ページの 5-12 の中綴じは 2 枚になり、1 枚目の表は [12|5]、裏は [6|11]、2 枚目は [10|7] と [8|9] になる")
    func bookletOfRange() {
        let plan = Imposition.plan(pages: [4, 5, 6, 7, 8, 9, 10, 11], layout: .a3BookletA4)
        #expect(plan.sheetCount == 2)
        #expect(plan.logicalPageCount == 8)
        #expect(plan.sides.map(\.slots) == [[11, 4], [5, 10], [9, 6], [7, 8]])
        #expect(plan.sides.map(\.isBack) == [false, true, false, true])
    }

    @Test("3 ページを選んだ両面は 2 枚になり、最後の裏は白紙になる")
    func duplexOfThree() {
        let plan = Imposition.plan(pages: [1, 3, 5], layout: .a4Duplex)
        #expect(plan.sheetCount == 2)
        #expect(plan.sides.map(\.slots) == [[1], [3], [5], [nil]])
    }

    @Test("3 ページを選んだ 2 アップは 2 枚になり、最後の右半分は白紙になる")
    func twoUpOfThree() {
        let plan = Imposition.plan(pages: [1, 3, 5], layout: .a3TwoUp)
        #expect(plan.sheetCount == 2)
        #expect(plan.sides.map(\.slots) == [[1, 3], [5, nil]])
    }

    @Test("5 ページを選んだ中綴じは 8 ページに揃え、足りない所は白紙にする")
    func bookletBlanks() {
        let plan = Imposition.plan(pages: [10, 11, 12, 13, 14], layout: .a4BookletA5)
        #expect(plan.sides.map(\.slots) == [[nil, 10], [11, nil], [nil, 12], [13, 14]])
    }

    @Test("全ページを順に選ぶと、ページ数からの面付けと同じになる")
    func sameAsWhole() {
        #expect(
            Imposition.plan(pages: Array(0..<12), layout: .a3BookletA4)
                == Imposition.plan(pageCount: 12, layout: .a3BookletA4))
    }
}
