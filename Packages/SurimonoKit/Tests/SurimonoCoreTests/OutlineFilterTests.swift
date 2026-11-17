import SurimonoCore
import Testing

struct OutlineFilterTests {
    @Test("空白だけの検索は全項目を文書順に返す", arguments: ["", "　 \t\n"])
    func emptyQuery(query: String) {
        let entries = [
            OutlineEntry(level: 1, title: "甲", pageIndex: nil), OutlineEntry(level: 2, title: "乙", pageIndex: 0),
        ]
        #expect(OutlineFilter.matches(in: entries, query: query) == [0, 1])
    }

    @Test("全角空白や改行で分けたすべての語を含む項目だけが残る")
    func allWords() {
        let entries = ["青い空と海", "青い空", "海と青い空", "青い海"].map { OutlineEntry(level: 1, title: $0, pageIndex: nil) }
        #expect(OutlineFilter.matches(in: entries, query: "海　青い\n空") == [0, 2])
    }

    @Test("文字幅と大小文字とアクセントと互換文字を同一視する", arguments: ["cafe a4 fi", "ＣＡＦÉ Ａ４ ﬁ"])
    func compatibility(query: String) {
        let entries = ["Ｃａｆé Ａ４ ﬁ", "cafe a4 fi"].map { OutlineEntry(level: 1, title: $0, pageIndex: 0) }
        #expect(OutlineFilter.matches(in: entries, query: query) == [0, 1])
    }

    @Test("ひらがなで打っても半角と全角カタカナの見出しが残る", arguments: ["がいど", "ガイド", "ｶﾞｲﾄﾞ"])
    func kana(query: String) {
        let entries = ["ガイド", "ｶﾞｲﾄﾞ", "がいど"].map { OutlineEntry(level: 1, title: $0, pageIndex: nil) }
        #expect(OutlineFilter.matches(in: entries, query: query) == [0, 1, 2])
    }

    @Test("目次が空か一致しなければ空を返す")
    func noMatches() {
        #expect(OutlineFilter.matches(in: [], query: "") == [])
        #expect(OutlineFilter.matches(in: [OutlineEntry(level: 1, title: "甲", pageIndex: 0)], query: "乙") == [])
    }

    @Test("一万項目でも複数語の一致を文書順に返す")
    func largeOutline() {
        let entries = (0..<10_000).map { OutlineEntry(level: 1, title: "ガイド Ｃａｆé 項目\($0)", pageIndex: $0) }
        #expect(OutlineFilter.matches(in: entries, query: "がいど cafe 9999") == [9999])
    }
}
