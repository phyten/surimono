import Foundation
import SurimonoFormats
import Testing

struct MarkdownIncludesTests {
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

    @Test("読み直した親から同じ規則で前書きを作る")
    func prefaceOfData() {
        #expect(MarkdownIncludes.prefaceData(Data("本文\n<<[a.md]\n".utf8)) == Data("本文\n".utf8))
    }
}
