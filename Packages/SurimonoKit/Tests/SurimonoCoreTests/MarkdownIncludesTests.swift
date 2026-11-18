import Foundation
import SurimonoCore
import Testing

struct MarkdownIncludesTests {
    private let parent = URL(fileURLWithPath: "/fixtures/book/index.md")

    private func plan(_ text: String, existing: Set<String>) throws -> MarkdownIncludes.Plan {
        try #require(MarkdownIncludes(markdown: text))
            .plan(parent: parent, exists: { existing.contains($0.path) })
    }

    @Test("見つからない文書と読まないパスを除いて計画を作る")
    func planDropsMissing() throws {
        let plan = try plan(
            "本文\n\n<<[a.md]\n<<[gone.md]\n<<[../out.md]\n<<[b.pdf]\n",
            existing: ["/fixtures/book/a.md", "/fixtures/book/b.pdf"])
        #expect(
            plan.documents == [
                URL(fileURLWithPath: "/fixtures/book/a.md"), URL(fileURLWithPath: "/fixtures/book/b.pdf"),
            ])
        #expect(plan.missing == ["gone.md", "../out.md"])
        #expect(plan.hasPreface)
        #expect(plan.offersBinder)
    }

    @Test("読める文書が 1 つなら合本に誘わない")
    func oneDocument() throws {
        let plan = try plan("本文\n\n<<[a.md]\n<<[gone.md]\n", existing: ["/fixtures/book/a.md"])
        #expect(!plan.offersBinder)
    }

    @Test("親自身を指す行は文書に数えない")
    func selfReference() throws {
        let plan = try plan(
            "<<[index.md]\n<<[a.md]\n<<[b.md]\n",
            existing: ["/fixtures/book/index.md", "/fixtures/book/a.md", "/fixtures/book/b.md"])
        #expect(plan.documents.map(\.lastPathComponent) == ["a.md", "b.md"])
        #expect(!plan.hasPreface)
    }

    @Test("合本にできない形式の文書は除外として分ける")
    func unsupported() throws {
        let plan = try plan(
            "<<[a.md]\n<<[b.zip]\n<<[c.md]\n",
            existing: ["/fixtures/book/a.md", "/fixtures/book/b.zip", "/fixtures/book/c.md"])
        #expect(plan.documents.map(\.lastPathComponent) == ["a.md", "c.md"])
        #expect(plan.excluded == [URL(fileURLWithPath: "/fixtures/book/b.zip")])
    }

    @Test("シンボリックリンクで親のフォルダーの外へ出る文書は読まない")
    func symbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.md")
        try Data("外".utf8).write(to: outside)
        try Data("中".utf8).write(to: book.appendingPathComponent("inside.md"))
        try FileManager.default.createSymbolicLink(
            at: book.appendingPathComponent("link.md"), withDestinationURL: outside)
        let plan = try #require(MarkdownIncludes(markdown: "<<[inside.md]\n<<[link.md]\n"))
            .plan(parent: book.appendingPathComponent("index.md"))
        #expect(plan.documents.map(\.lastPathComponent) == ["inside.md"])
        #expect(plan.missing == ["link.md"])
    }
}
