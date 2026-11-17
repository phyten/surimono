import Foundation
import SurimonoCore
import Testing

struct ReadingPositionTests {
    @Test("目次が変わらなければすべてのページへそのまま戻る")
    func unchanged() {
        let outlines: [[OutlineEntry]] = [
            [],
            [
                .init(level: 1, title: "甲", pageIndex: 2), .init(level: 2, title: "節", pageIndex: 2),
                .init(level: 1, title: "乙", pageIndex: 7),
            ],
            [
                .init(level: 1, title: "同名", pageIndex: 1), .init(level: 1, title: "同名", pageIndex: nil),
                .init(level: 1, title: "同名", pageIndex: 6),
            ],
        ]
        for entries in outlines {
            for page in 0..<12 {
                #expect(
                    ReadingPosition(page: page, pageCount: 12, entries: entries).page(pageCount: 12, entries: entries)
                        == page)
            }
        }
    }

    @Test("見出しの区間が倍になれば進みも倍になる")
    func expandedSection() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 2), .init(level: 2, title: "節", pageIndex: 12),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 4), .init(level: 2, title: "節", pageIndex: 24),
        ]
        #expect(ReadingPosition(page: 7, pageCount: 30, entries: old).page(pageCount: 40, entries: new) == 14)
    }

    @Test("短くなった区間を越えず次の見出しの手前へ戻る")
    func contractedSection() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 0), .init(level: 1, title: "乙", pageIndex: 10),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 3), .init(level: 1, title: "乙", pageIndex: 5),
        ]
        #expect(ReadingPosition(page: 9, pageCount: 20, entries: old).page(pageCount: 20, entries: new) == 4)
    }

    @Test("区間内の割合は四捨五入する")
    func roundsSection() {
        let entries: [OutlineEntry] = [.init(level: 1, title: "甲", pageIndex: 0)]
        #expect(ReadingPosition(page: 1, pageCount: 4, entries: entries).page(pageCount: 6, entries: entries) == 2)
    }

    @Test("同じ題名とレベルの出現順でページ不明の項目も数える")
    func repeatedHeading() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "同名", pageIndex: nil), .init(level: 2, title: "同名", pageIndex: 0),
            .init(level: 1, title: "同名", pageIndex: 5),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "同名", pageIndex: 1), .init(level: 2, title: "同名", pageIndex: 2),
            .init(level: 1, title: "同名", pageIndex: 8),
        ]
        #expect(ReadingPosition(page: 7, pageCount: 10, entries: old).page(pageCount: 13, entries: new) == 10)
    }

    @Test("次の見出しのページが不明ならその先の既知の見出しまでを区間にする")
    func skipsUnknownEnd() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 0), .init(level: 2, title: "不明", pageIndex: nil),
            .init(level: 1, title: "乙", pageIndex: 10),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 0), .init(level: 2, title: "不明", pageIndex: nil),
            .init(level: 1, title: "乙", pageIndex: 20),
        ]
        #expect(ReadingPosition(page: 5, pageCount: 30, entries: old).page(pageCount: 30, entries: new) == 10)
    }

    @Test("見出しが消えたかページ不明になったら文書全体の割合へ戻る")
    func fallback() {
        let old: [OutlineEntry] = [.init(level: 1, title: "甲", pageIndex: 2)]
        let position = ReadingPosition(page: 5, pageCount: 11, entries: old)
        #expect(position.page(pageCount: 16, entries: []) == 8)
        #expect(position.page(pageCount: 16, entries: [.init(level: 1, title: "甲", pageIndex: nil)]) == 8)
        #expect(position.page(pageCount: 16, entries: [.init(level: 2, title: "甲", pageIndex: 0)]) == 8)
    }

    @Test("範囲外のページは文書内へ収めて覚える", arguments: [Int.min, -1, 12, Int.max])
    func clampsInput(page: Int) {
        let position = ReadingPosition(page: page, pageCount: 12, entries: [])
        #expect(position.page(pageCount: 12, entries: []) == (page < 0 ? 0 : 11))
    }

    @Test("ページが一つ以下なら割合はゼロで戻り先も範囲内になる", arguments: [Int.min, -1, 0, 1])
    func emptyDocument(pageCount: Int) {
        let position = ReadingPosition(page: 8, pageCount: pageCount, entries: [])
        #expect(position.page(pageCount: 20, entries: []) == 0)
        #expect(position.page(pageCount: pageCount, entries: []) == 0)
    }

    @Test("同じページに見出しが重なったら最後の見出しを覚える")
    func sharedPage() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 2), .init(level: 2, title: "節", pageIndex: 2),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 2), .init(level: 2, title: "節", pageIndex: 5),
        ]
        #expect(ReadingPosition(page: 2, pageCount: 10, entries: old).page(pageCount: 10, entries: new) == 5)
    }

    @Test("復元した見出しが文書外でも最終ページに収める")
    func clampsOutput() {
        let position = ReadingPosition(page: 3, pageCount: 10, entries: [.init(level: 1, title: "甲", pageIndex: 2)])
        #expect(position.page(pageCount: 5, entries: [.init(level: 1, title: "甲", pageIndex: Int.max)]) == 4)
    }

    @Test("符号化して復号しても読む位置が変わらない")
    func codable() throws {
        let entries: [OutlineEntry] = [.init(level: 1, title: "甲", pageIndex: 2)]
        let position = ReadingPosition(page: 5, pageCount: 12, entries: entries)
        let restored = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(position))
        #expect(restored == position)
        #expect(restored.page(pageCount: 12, entries: entries) == 5)
    }
    @Test("最初の見出しより前では全体の割合で戻る")
    func beforeFirstHeading() {
        let entries: [OutlineEntry] = [.init(level: 1, title: "甲", pageIndex: 4)]
        #expect(ReadingPosition(page: 2, pageCount: 11, entries: entries).page(pageCount: 21, entries: entries) == 4)
    }

    @Test("覚えた出現番号がなくなったら別の同名見出しに戻らない")
    func missingOccurrence() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "同名", pageIndex: 0), .init(level: 1, title: "同名", pageIndex: 5),
        ]
        let new: [OutlineEntry] = [.init(level: 1, title: "同名", pageIndex: 1)]
        #expect(ReadingPosition(page: 5, pageCount: 11, entries: old).page(pageCount: 21, entries: new) == 10)
    }

    @Test("見出しがあっても範囲外の入力を収めて覚える")
    func clampsWithHeading() {
        let entries: [OutlineEntry] = [.init(level: 1, title: "甲", pageIndex: 0)]
        #expect(
            ReadingPosition(page: Int.min, pageCount: 10, entries: entries).page(pageCount: 10, entries: entries) == 0)
        #expect(
            ReadingPosition(page: Int.max, pageCount: 10, entries: entries).page(pageCount: 10, entries: entries) == 9)
    }

    @Test("組み直しで次の見出しと同じページになったらそのページへ戻る")
    func collapsedSection() {
        let old: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 0), .init(level: 1, title: "乙", pageIndex: 10),
        ]
        let new: [OutlineEntry] = [
            .init(level: 1, title: "甲", pageIndex: 2), .init(level: 1, title: "乙", pageIndex: 2),
        ]
        #expect(ReadingPosition(page: 5, pageCount: 20, entries: old).page(pageCount: 5, entries: new) == 2)
    }

}
