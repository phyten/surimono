import Testing

@testable import SurimonoCore

struct ReadingBookmarkTests {
    @Test("見出しのない文書にはしおりを作らない")
    func empty() {
        #expect(ReadingBookmark.tree(from: []).isEmpty)
    }

    @Test("同じ階層は兄弟として原文の順に並ぶ")
    func siblings() {
        let entries = [entry(2, "One", 0), entry(2, "Two", 1)]
        let tree = ReadingBookmark.tree(from: entries)
        #expect(tree.map(\.entry) == entries)
        #expect(tree.allSatisfy { $0.children.isEmpty })
    }

    @Test("飛び越した階層は直前の浅い見出しの子になり戻ると兄弟になる")
    func skippedLevels() {
        let tree = ReadingBookmark.tree(from: [
            entry(1, "Title", 0), entry(3, "Deep", 1), entry(4, "Deeper", 2),
            entry(2, "Chapter", 3), entry(1, "Next", 4),
        ])
        #expect(tree.map(\.entry.title) == ["Title", "Next"])
        #expect(tree[0].children.map(\.entry.title) == ["Deep", "Chapter"])
        #expect(tree[0].children[0].children.map(\.entry.title) == ["Deeper"])
    }

    private func entry(_ level: Int, _ title: String, _ page: Int) -> OutlineEntry {
        OutlineEntry(level: level, title: title, pageIndex: page)
    }
}
