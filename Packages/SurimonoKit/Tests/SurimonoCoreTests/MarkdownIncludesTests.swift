import Foundation
import SurimonoCore
import Testing

struct MarkdownIncludesTests {
    private let parent = URL(fileURLWithPath: "/fixtures/book/index.md")

    private func plan(_ text: String, existing: Set<String>) throws -> MarkdownIncludes.Plan {
        try #require(MarkdownIncludes(markdown: text))
            .plan(parent: parent, exists: { existing.contains($0.path) })
    }

    @Test("Marked の <<[file] を順に読み、その行を前書きから除く")
    func marked() throws {
        let includes = try #require(
            MarkdownIncludes(markdown: "# 手引き\n\nはじめに。\n\n<<[01-intro.md]\n\n## 毎日\n\n<<[sub/02-hours.md]\n"))
        #expect(includes.paths == ["01-intro.md", "sub/02-hours.md"])
        #expect(includes.refused.isEmpty)
        #expect(includes.preface == "# 手引き\n\nはじめに。\n\n\n## 毎日\n\n")
    }

    @Test("MultiMarkdown の {{file}} を読む")
    func multiMarkdown() throws {
        let includes = try #require(MarkdownIncludes(markdown: "{{01-intro.md}}\n{{ 02.org }}\n"))
        #expect(includes.paths == ["01-intro.md", "02.org"])
    }

    @Test("{{TOC}} とワイルドカードと拡張子のない波かっこは取り込みにしない")
    func multiMarkdownLookalikes() {
        #expect(MarkdownIncludes(markdown: "{{TOC}}\n\n{{chapter.*}}\n\n{{ title }}\n") == nil)
    }

    @Test("iA Writer の行に単独の /file を読む")
    func iaWriter() throws {
        let includes = try #require(MarkdownIncludes(markdown: "前書き\n\n/01-intro.md\n\n/sub/図 1.png\n"))
        #expect(includes.paths == ["01-intro.md", "sub/図 1.png"])
    }

    @Test("拡張子のないスラッシュの行は取り込みにしない")
    func iaWriterLookalikes() {
        #expect(MarkdownIncludes(markdown: "/usr/bin\n\n/remind me\n") == nil)
    }

    @Test("文の途中の記法は取り込みにしない")
    func inlineSyntax() {
        #expect(
            MarkdownIncludes(markdown: "本文の <<[a.md] と {{b.md}} は文字のまま。\n\n見て /c.md を\n\n- <<[d.md]\n") == nil)
    }

    @Test("コードブロックの中の記法は取り込みにしない")
    func codeBlocks() throws {
        let text = "```\n<<[a.md]\n```\n\n~~~~ md\n{{b.md}}\n~~~\n/c.md\n~~~~\n\n    <<[d.md]\n\n<<[e.md]\n"
        let includes = try #require(MarkdownIncludes(markdown: text))
        #expect(includes.paths == ["e.md"])
        #expect(includes.preface?.contains("<<[a.md]") == true)
    }

    @Test("閉じていないコードブロックの後は読まない")
    func unclosedFence() {
        #expect(MarkdownIncludes(markdown: "```\n<<[a.md]\n") == nil)
    }

    @Test("3 字までの字下げと行末の空白と CRLF を許す")
    func whitespace() throws {
        let includes = try #require(MarkdownIncludes(markdown: "   <<[a.md]  \r\n{{b.md}}\t\r\n"))
        #expect(includes.paths == ["a.md", "b.md"])
    }

    @Test("同じ文書を二度指しても一度だけ読み、どちらの行も前書きから除く")
    func duplicates() throws {
        let includes = try #require(MarkdownIncludes(markdown: "<<[a.md]\n<<[./a.md]\n本文\n"))
        #expect(includes.paths == ["a.md"])
        #expect(includes.preface == "本文\n")
    }

    @Test(
        "親のフォルダーの外へ出るパスと絶対パスと URL は読まない",
        arguments: [
            "../a.md", "b/../../a.md", "/etc/hosts.md", "~/a.md", "file:///etc/hosts.md", "https://example.com/a.md",
        ])
    func refused(_ path: String) throws {
        let includes = try #require(MarkdownIncludes(markdown: "<<[\(path)]\n"))
        #expect(includes.paths.isEmpty)
        #expect(includes.refused == [path])
    }

    @Test("iA の参照でも // で始まる絶対パスは読まない")
    func iaWriterAbsolute() throws {
        let includes = try #require(MarkdownIncludes(markdown: "//etc/hosts.md\n"))
        #expect(includes.paths.isEmpty)
        #expect(includes.refused == ["/etc/hosts.md"])
    }

    @Test("フォルダーの内側で閉じる .. は読む")
    func innerParent() throws {
        let includes = try #require(MarkdownIncludes(markdown: "<<[a/../b/./c.md]\n"))
        #expect(includes.paths == ["b/c.md"])
    }

    @Test("リストのリンクだけの文書を目次として読み、前書きを持たない")
    func summary() throws {
        let text = """
            # 目次

            - [はじめに](01-intro.md)
            - [開館と閉館](02-hours.md)
                - [夜](sub/night.md#start)

            ## 付録

            1. [付録 A](my%20appendix.md)

            ---
            """
        let includes = try #require(MarkdownIncludes(markdown: text))
        #expect(includes.paths == ["01-intro.md", "02-hours.md", "sub/night.md", "my appendix.md"])
        #expect(includes.preface == nil)
    }

    @Test("目次の外部リンクと空のリンクは文書に数えない")
    func summaryExternalLinks() throws {
        let includes = try #require(
            MarkdownIncludes(markdown: "- [a](a.md)\n- [web](https://example.com/b.md)\n- [予定]()\n- [上](#top)\n"))
        #expect(includes.paths == ["a.md"])
        #expect(includes.refused.isEmpty)
    }

    @Test("本文のある文書やリンク以外の項目がある文書は目次にしない")
    func notSummary() {
        #expect(MarkdownIncludes(markdown: "説明です。\n\n- [a](a.md)\n- [b](b.md)\n") == nil)
        #expect(MarkdownIncludes(markdown: "- [a](a.md) と説明\n- [b](b.md)\n") == nil)
        #expect(MarkdownIncludes(markdown: "- 項目\n- [b](b.md)\n") == nil)
        #expect(MarkdownIncludes(markdown: "# 見出しだけ\n") == nil)
        #expect(MarkdownIncludes(markdown: "- [web](https://example.com)\n") == nil)
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

    @Test("読み直した親から同じ規則で前書きを作る")
    func prefaceOfData() {
        #expect(MarkdownIncludes.prefaceData(Data("本文\n<<[a.md]\n".utf8)) == Data("本文\n".utf8))
    }
}
