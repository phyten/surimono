import Foundation
import RobustnessSupport
import Testing

@testable import SurimonoFormats

struct MarkdownCitationTests {
    private let directory = URL(filePath: "/papers")
    private let first = """
        @book{knuth, author={Donald Knuth}, title={The Art of Programming}, year={1968}}
        @book{paper.2:a/b-c_d, author={Ada Lovelace}, title={Notes}, year={1843}}
        """
    private let second = """
        @book{unused, author={Claude Shannon}, title={Communication}, year={1948}}
        """

    private func convert(_ body: String, metadata: String = "") -> HTMLFragment {
        MarkdownConverter.convert(
            "---\nbibliography: [refs.bib, 'other sources.bib']\n\(metadata)\n---\n\(body)", directory: directory
        ) { url in
            switch url {
            case directory.appending(path: "refs.bib"): Data(first.utf8)
            case directory.appending(path: "other sources.bib"): Data(second.utf8)
            default: nil
            }
        }
    }

    @Test("数値引用を初出順に並べ、本文中の引用には著者を付ける")
    func citations() {
        let result = convert(
            "See [@paper.2:a/b-c_d]. @knuth. [@knuth, p. 33]. [see @knuth, pp. 33-35; @paper.2:a/b-c_d]. [-@knuth].")
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains(##"[<a href="#bib-db-1">1</a>]"##))
        #expect(result.body.contains(##"Knuth [<a href="#bib-db-2">2</a>]"##))
        #expect(result.body.contains(##"[<a href="#bib-db-2">2</a>, p. 33]"##))
        #expect(result.body.contains(##"[see <a href="#bib-db-2">2</a>, pp. 33-35; <a href="#bib-db-1">1</a>]"##))
        #expect(result.body.contains(##"class="latex-cite">[<a href="#bib-db-2">2</a>]"##))
        #expect(!result.body.contains("Shannon"))
        #expect(result.body.contains(#"<li id="bib-db-1"><span class="bib-label">[1]</span> Ada Lovelace."#))
    }

    @Test("括弧内の鍵と登録済みの本文中の鍵は先頭と末尾の記号を保つ")
    func punctuation() {
        let source = "---\nbibliography: refs.bib\n---\n[@/key.] and @/key. Also @other."
        let fragment = MarkdownConverter.convert(source, directory: directory) { _ in
            Data(
                "@book{/key.,author={Ada Lovelace},title={Notes}}\n@book{other,author={Donald Knuth},title={Paper}}"
                    .utf8)
        }
        #expect(fragment.body.contains(##"Lovelace [<a href="#bib-db-1">1</a>]</span> Also"##))
        #expect(fragment.body.contains(##"Knuth [<a href="#bib-db-2">2</a>]</span>."##))
    }

    @Test("引用しない領域の記号を残す")
    func protected() {
        let result = convert(
            #"""
            user@example.com abc@knuth 日本@knuth \@knuth [\@knuth]

            `[@knuth]` and `@knuth`.

            ```
            @knuth
            ```

            <div>
            [@knuth]
            </div>

            [page](https://example.org/@knuth) https://example.org/@knuth

            [nested](https://example.org/path(foo(bar))/@knuth)

            file:///tmp/@knuth

            [elsewhere][link]

            [link]: https://example.org/@knuth
            """#)
        #expect(!result.body.contains("latex-cite"))
        #expect(!result.body.contains("latex-bibliography"))
        #expect(result.body.contains("abc@knuth 日本@knuth @knuth [@knuth]"))
        #expect(result.body.contains("<code>[@knuth]</code>"))
        #expect(result.body.contains("<div>\n[@knuth]"))
        #expect(result.body.contains("mailto:user@example.com"))
        #expect(result.body.contains("https://example.org/@knuth"))
    }

    @Test("文献ファイルの指定がなければ引用は原文のまま")
    func noBibliography() {
        let fragment = MarkdownConverter.convert("@knuth [@missing] [-@knuth]")
        #expect(fragment.body == "<p>@knuth [@missing] [-@knuth]</p>\n")
    }

    @Test("未解決の鍵を太字で残し、次の文献番号を消費しない")
    func missing() {
        let fragment = convert("[@missing] [@knuth]")
        #expect(fragment.body.contains(#"<strong class="latex-missing">@missing?</strong>"#))
        #expect(fragment.body.contains(##"[<a href="#bib-db-1">1</a>]"##))
    }

    @Test("全件または指定された未引用文献を引用済みの後に加える", arguments: ["'@*'", "['@unused']"])
    func nocite(value: String) {
        let result = convert("[@knuth]", metadata: "nocite: \(value)")
        #expect(result.body.contains("Claude Shannon"))
        #expect(result.body.contains("Ada Lovelace") == (value == "'@*'"))
        #expect(result.body.contains(#"<li id="bib-db-1"><span class="bib-label">[1]</span> Donald Knuth."#))
    }

    @Test("文献欄を指定位置に一度だけ置き、見出しとリンク設定に従う")
    func refs() throws {
        let fragment = convert(
            "::: {#refs}\n:::\n\nNext [@knuth].\n\n::: {#refs}\n:::",
            metadata: "reference-section-title: 'Sources & notes'\nlink-citations: false")
        let entry = try #require(fragment.body.range(of: "Sources &amp; notes"))
        let later = try #require(fragment.body.range(of: "Next "))
        #expect(entry.lowerBound < later.lowerBound)
        #expect(fragment.body.contains(#"<div id="refs">"#))
        #expect(!fragment.body.contains("href="))
        #expect(fragment.body.components(separatedBy: "latex-bibliography-heading").count == 2)
        #expect(fragment.body.contains(#"class="latex-cite">[1]"#))
    }

    @Test("文献の見出しには文書の言語を使う")
    func japanese() {
        #expect(convert("この方法で確かめた [@knuth]。").body.contains(">参考文献</h2>"))
        #expect(convert("[@knuth]", metadata: "lang: ja-JP").body.contains(">参考文献</h2>"))
        #expect(convert("[@knuth]", metadata: "lang: en").body.contains(">References</h2>"))
    }

    @Test("読めない文献と未対応のスタイルを組版前の問題にまとめる")
    func fileIssues() {
        let attempts = Locked<[URL]>([])
        let fragment = MarkdownConverter.convert(
            "---\nbibliography:\n  - sources/paper.bib\n  - sources/paper.bib\ncsl: modern.csl\n---\n[@none]",
            directory: directory
        ) {
            attempts.value.append($0)
            return nil
        }
        #expect(Set(attempts.value) == [directory.appending(path: "sources/paper.bib")])
        #expect(
            fragment.readingIssues == [
                "sources/paper.bib could not be read", "CSL styles are not supported; numeric citations are used.",
            ])
        #expect(!fragment.body.contains("modern.csl"))
    }

    @Test("先頭が一級見出しのときだけ前付けの表題を省き、目次は本文の前に置く")
    func frontMatter() throws {
        let metadata = "---\ntitle: 'Paper & ink'\nauthor:\n  - 'K, A.'\n  - B\ndate: 2026-11-19\ntoc: true\n---\n"
        let fragment = MarkdownConverter.convert(metadata + "Opening\n\n# Later").body
        #expect(fragment.hasPrefix(#"<header class="latex-title-block">"#))
        #expect(fragment.contains(">Paper &amp; ink</h1>"))
        #expect(fragment.contains(">K, A.</span>"))
        #expect(fragment.contains(">B</span>"))
        #expect(fragment.contains(">2026-11-19</p>"))
        let toc = try #require(fragment.range(of: "<nav"))
        let opening = try #require(fragment.range(of: "<p>Opening"))
        #expect(toc.lowerBound < opening.lowerBound)
        #expect(!MarkdownConverter.convert(metadata + "\n# First\n\nText").body.contains("latex-title"))
        #expect(!MarkdownConverter.convert("---\nauthor: someone\n---\nOpening").body.contains("latex-author"))
    }

    @Test("目次は本文で決めた番号を表示し、見出しへのリンクを保つ")
    func headingCitations() {
        let fragment = convert(
            "First [@knuth].\n\n# About @unused {#reading}\n\nRead.[^one]\n\n[^one]: [@knuth]", metadata: "toc: true")
        #expect(fragment.body.contains(##"<a href="#reading">About Shannon [2]</a>"##))
        #expect(
            fragment.body.contains(
                ##"id="reading">About <span class="latex-cite">Shannon [<a href="#bib-db-2">2</a>]"##))
        #expect(fragment.body.contains(##"<li id="fn-1"><p><span class="latex-cite">[<a href="#bib-db-1">1</a>]"##))
    }

    @Test("属性付きの囲みは既知の種類を装飾し、任意のクラスと識別子を保持する")
    func attributes() {
        let body = MarkdownConverter.convert(
            """
            ::: {.note}
            **note body**
            :::

            ::: {.warning #stop}
            Careful
            :::

            ::: {.columns .wide #shelf}
            *paper*
            :::
            """
        ).body
        #expect(body.contains(#"class="callout callout-note note""#))
        #expect(body.contains(#"class="callout callout-warning warning" data-callout="warning" id="stop""#))
        #expect(body.contains(#"<div class="columns wide" id="shelf">"#))
        #expect(body.contains("<em>paper</em>"))
    }
}
