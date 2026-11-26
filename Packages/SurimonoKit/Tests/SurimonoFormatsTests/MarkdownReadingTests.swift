import Foundation
import Testing

@testable import SurimonoFormats

struct MarkdownReadingTests {
    // Captured from MarkdownConverter at cc538d8e, including the final newline.
    @Test("既定の本文は従来の見出し・表題・二つの目次・脚注までバイト単位で一致する")
    func originalBytes() {
        let cases = [
            (
                "# An *inline* `heading` {#top}\n\nFirst\nsecond",
                """
                <h1 id="top">An <em>inline</em> <code>heading</code></h1>
                <p>First
                second</p>
                """ + "\n"
            ),
            (
                "---\ntitle: Header\nauthor: Author\n---\n## One",
                """
                <header class="latex-title-block">
                <h1 class="latex-title">Header</h1>
                <p class="latex-author"><span class="latex-author-name">Author</span></p>
                </header>
                <h2 id="one">One</h2>
                """ + "\n"
            ),
            (
                "---\ntoc: true\n---\n# Book\n\n## A\n\n[TOC]\n\n### B",
                """
                <nav class="toc"><ul><li><a href="#a">A</a><ul><li><a href="#b">B</a></li></ul></li></ul></nav>
                <h1 id="book">Book</h1>
                <h2 id="a">A</h2>
                <nav class="toc"><ul><li><a href="#a">A</a><ul><li><a href="#b">B</a></li></ul></li></ul></nav>
                <h3 id="b">B</h3>
                """ + "\n"
            ),
            (
                "Text[^n].\n\n[^n]: First\n    second",
                """
                <p>Text<sup class="footnote-ref"><a href="#fn-1" id="fnref-1">1</a></sup>.</p>
                <section class="footnotes">
                <ol>
                <li id="fn-1"><p>First
                second</p>
                </li>
                </ol>
                </section>
                """ + "\n"
            ),
        ]
        for (source, expected) in cases {
            let fragment = MarkdownConverter.convert(source)
            #expect(Data(fragment.body.utf8) == Data(expected.utf8))
            #expect(!fragment.decidesHeadingNumbers)
        }
    }
}

extension MarkdownReadingTests {
    @Test("三つの読み方を独立に本文・見出し・先頭と本文の目次へ反映する", arguments: [false, true], [false, true])
    func combinations(numbered: Bool, lead: Bool) {
        for breaks in [false, true] {
            var reading = MarkdownReadingSettings()
            reading.document.set(
                .outline(present: numbered, depth: .levels(1)), for: .sectionNumbers, format: .markdown)
            reading.document.set(.outline(present: lead, depth: .levels(1)), for: .tableOfContents, format: .markdown)
            reading.document.set(.toggle(breaks), for: .preserveBreaks, format: .markdown)
            let text =
                "# Book\n\n## *One* {#stable}\n\n### Child\n\n## Two\n\n[TOC]\n\nFirst\nnext[^n]\n\n[^n]: Foot\n    note"
            let fragment = MarkdownConverter.convert(text, reading: reading)
            let html = fragment.body
            #expect(html.contains(numbered ? "id=\"stable\">1. <em>One" : "id=\"stable\"><em>One"))
            #expect(html.contains(numbered ? "href=\"#stable\">1. One" : "href=\"#stable\">One"))
            #expect(html.contains("id=\"child\">Child") && html.contains("href=\"#child\">Child"))
            #expect(html.contains(numbered ? "id=\"two\">2. Two" : "id=\"two\">Two"))
            #expect(html.components(separatedBy: "<nav ").count == (lead ? 3 : 2))
            #expect(html.contains(breaks ? "First<br>\nnext" : "First\nnext"))
            #expect(html.contains(breaks ? "Foot<br>\nnote" : "Foot\nnote"))
            #expect(fragment.contentsInstructions == .init())
            #expect(fragment.decidesHeadingNumbers == numbered)
        }
    }

    @Test("BOM と CRLF の原稿から最上位の指定と行番号だけを読む")
    func yaml() throws {
        let yaml = [
            "---", "format:", "  html:", "    toc: false", "    toc-depth: 5", "    number-sections: true",
            "    toc-title: Nested", "toc: TRUE # on", "toc-depth: 1", "toc-title: 'A # & B'", "---", "# Book", "## A",
            "### B",
        ]
        let fragment = MarkdownConverter.convert("\u{FEFF}" + yaml.joined(separator: "\r\n"))
        let file = fragment.contentsInstructions
        #expect(file.present?.value == true && file.present?.source?.lineNumber == 8)
        #expect(file.present?.source?.rawText == "toc: TRUE # on")
        #expect(file.depth?.value == .levels(1) && file.depth?.source?.lineNumber == 9)
        #expect(fragment.body.contains(">A # &amp; B</p>") && !fragment.body.contains("href=\"#b\""))
        #expect(fragment.numberInstructions == .init() && !fragment.decidesHeadingNumbers)
    }

    @Test("真偽値でない有無と整数でない深さは設定を固定しない", arguments: ["maybe", "1.5", "[true]", "'true'", ""])
    func invalid(_ value: String) {
        let text = "---\ntoc: \(value)\nnumber-sections: \(value)\ntoc-depth: \(value)\n---\n[TOC]\n\n# A"
        let fragment = MarkdownConverter.convert(text)
        #expect(fragment.contentsInstructions == .init() && fragment.numberInstructions == .init())
        #expect(fragment.readingIssues.isEmpty && !fragment.decidesHeadingNumbers)
        #expect(fragment.body.components(separatedBy: "<nav ").count == 2)
    }

    @Test("保存済みの目次の値を引き継ぎ、上書きを許可して保存し直せる")
    func storedChoices() throws {
        let saved = #"{"markdown":{"tableOfContents":{"present":true,"depth":1}}}"#
        var choices = try JSONDecoder().decode(FormatReadingChoices.self, from: Data(saved.utf8))
        let text = "---\ntoc: false\n---\n# Book\n\n## One\n\n### Child"
        #expect(!MarkdownConverter.convert(text, reading: .init(document: choices)).body.contains("<nav"))
        choices.setAllowsFileChanges(true, for: .markdown)
        let restored = try JSONDecoder().decode(FormatReadingChoices.self, from: JSONEncoder().encode(choices))
        let html = MarkdownConverter.convert(text, reading: .init(document: restored)).body
        #expect(html.contains("href=\"#one\"") && !html.contains("href=\"#child\""))
        #expect(restored.restricted(to: [.quarto]).isEmpty)
    }
}
