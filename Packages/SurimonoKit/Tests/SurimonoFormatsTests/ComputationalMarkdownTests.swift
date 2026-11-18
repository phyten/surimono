import Foundation
import Testing

@testable import SurimonoFormats

struct ComputationalMarkdownTests {
    @Test("表題と文書の言語を取り出し著者と要旨を印刷する")
    func metadata() {
        let result = ComputationalMarkdown.convert(
            """
            ---
            title: 'Paper'
            author:
              - name: Aoki
                affiliation: Lab
              - name: Mori
            abstract: >
              First
              paragraph
            lang: ja
            date: today
            ---
            Body
            """)
        #expect(result.title == "Paper")
        #expect(result.language == "ja")
        #expect(result.body.contains("Aoki, Mori"))
        #expect(result.body.contains("First paragraph"))
        #expect(!result.body.contains("today"))
    }

    @Test(
        "印刷する記法と非表示の記法を区別する",
        arguments: [
            ("~~~{r, echo=FALSE}\nsecret\n~~~", "chunk-result-note", "secret"),
            ("~~~{python}\n#| eval: false\nvalue\n~~~", "value", "chunk-result-note"),
            ("~~~{sql}\n--| include: false\nsecret\n~~~", "", "secret"),
            ("~~~{ojs}\n//| output: false\nvalue\n~~~", "language-javascript", "chunk-result-note"),
            ("~~~{mermaid}\n#| label: diagram\ngraph TD\n~~~", "mermaid-block", "#|"),
            ("~~~{dot}\ndigraph {}\n~~~", "digraph", "chunk-result-note"),
            ("~~~{.r filename=\"example.R\"}\nvalue\n~~~", "example.R", "chunk-result-note"),
            ("~~~{=html}\n<b>paper</b>\n~~~", "<b>paper</b>", "=html"),
            ("~~~{=typst}\nsecret\n~~~", "", "secret"),
            ("::: {.hidden}\nsecret\n:::", "", "secret"),
            ("::: {.notes}\nsecret\n:::", "", "secret"),
            ("::: {.content-visible when-format=\"html\"}\nsecret\n:::", "", "secret"),
            ("::: {.content-hidden unless-format=\"pdf\"}\nPaper\n:::", "Paper", "unless-format"),
            ("::: {.callout-tip}\n## Title\nBody\n:::", "callout-tip", "<h2"),
            ("[Text]{.smallcaps}", "class=\"smallcaps\"", "{.smallcaps}"),
            ("Inline `{python} 2+2`", "inline-expression", "{python}"),
            ("Note^[Body]", "footnotes", "^["),
            ("{{< include other.qmd >}}", "other.qmd", "{{<"),
            ("Reference @sec-end\n\n# End {#sec-end}", "Section 1", "@sec-end"),
            ("---\nbroken YAML\n---\nBody", "<pre>", "chunk-result-note"),
        ])
    func markup(source: String, present: String, absent: String) {
        let html = ComputationalMarkdown.convert(source).body
        #expect(present.isEmpty || html.contains(present))
        #expect(!html.contains(absent))
    }

    @Test("結果だけのチャンクが続くと注記をまとめる")
    func merged() {
        let chunk = "~~~{r, echo=FALSE}\n42\n~~~"
        let html = ComputationalMarkdown.convert(chunk + "\n\n" + chunk).body
        #expect(html.components(separatedBy: "chunk-result-note").count == 2)
    }

    @Test("通常のMarkdownの囲みを保つ")
    func markdown() {
        #expect(MarkdownConverter.convert("::: warning\n注意\n:::").body.contains("callout-warning"))
    }

    @Test("実行の既定値にsetupのリテラルと各チャンクの指定を順に重ねる")
    func cascade() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            execute:
              echo: true
              eval: false
            ---
            ~~~{r setup, include=FALSE, eval=TRUE}
            knitr::opts_chunk$set(echo = FALSE)
            ~~~
            ~~~{r}
            privateCode
            ~~~
            ~~~{r}
            #| echo: true
            publicCode
            ~~~
            """
        ).body
        #expect(!html.contains("privateCode"))
        #expect(html.contains("publicCode"))
        #expect(!html.contains("chunk-result-note"))
    }

    @Test(
        "ラベルの種類ごとに前方参照へリンクを付ける",
        arguments: [
            ("fig-a", "![Paper](paper.png){#fig-a}", "Figure 1"),
            ("tbl-a", "| A | B |\n|---|---|\n| 1 | 2 |\n\n: Caption {#tbl-a}", "Table 1"),
            ("fig-a", "::: {#fig-a}\nBody\n\nCaption\n:::", "Figure 1"),
            ("tbl-a", "::: {#tbl-a}\nBody\n\nCaption\n:::", "Table 1"),
            ("sec-a", "# Chapter {#sec-a}", "Section 1"),
            ("eq-a", "$$\nx^2\n$$ {#eq-a}", "Equation 1"),
            ("thm-a", "::: {#thm-a}\nBody\n:::", "Theorem 1"),
            ("lem-a", "::: {#lem-a}\nBody\n:::", "Lemma 1"),
            ("def-a", "::: {#def-a}\nBody\n:::", "Definition 1"),
            ("exm-a", "::: {#exm-a}\nBody\n:::", "Example 1"),
        ])
    func reference(id: String, source: String, name: String) {
        let html = ComputationalMarkdown.convert("[@\(id)] [-@\(id)] @unknown\n\n" + source).body
        #expect(html.contains("<a href=\"#\(id)\">\(name)</a>"))
        #expect(html.contains("<a href=\"#\(id)\">1</a>"))
        #expect(html.contains("id=\"\(id)\""))
        #expect(html.contains("@unknown"))
    }

    @Test("bookdownのチャンク名を図番号に結びつける")
    func bookdown() {
        let html = ComputationalMarkdown.convert(
            "\\@ref(fig:cars)\n\n~~~{r cars, fig.cap='Cars', results='show'}\nx\n~~~"
        ).body
        #expect(html.contains("<a href=\"#fig:cars\">Figure 1</a>"))
        #expect(html.contains("Figure 1 Cars"))
    }

    @Test("章番号と目次に深さと見出しごとの指定を反映する")
    func contents() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            toc: true
            toc-title: Index
            toc-depth: 1
            number-sections: true
            ---
            # One {#sec-one}
            ## Deep
            # Extra {.unnumbered .unlisted}
            """
        ).body
        let nav = html.components(separatedBy: "</nav>")[0]
        #expect(nav.contains("Index"))
        #expect(nav.contains("1 One"))
        #expect(!nav.contains("Deep"))
        #expect(!nav.contains("Extra"))
        #expect(html.contains("1.1 Deep"))
    }

    @Test(
        "書誌と印刷用記法を扱う",
        arguments: [
            ("---\nauthor: [One, 'Two']\n---", "One, Two"),
            ("---\nauthor:\n- One\n- Two\n---", "One, Two"),
            ("---\ntitle: |\n  One\n  Two\n---", "One\nTwo"),
            ("---\ndate: 2026-11-18\n---", "2026-11-18"),
            ("---\nbibliography: items.bib\n---", "Bibliography"),
            ("---\nlang: ja\n---\n~~~{r}\n1\n~~~", "コードを実行しない"),
            ("---\ntitle: Paper\n---\n{{< meta title >}}", "<p>Paper</p>"),
            ("{{< var count >}}", "<code>{{&lt; var count &gt;}}</code>"),
            ("{{< pagebreak >}}", "page-break"),
            ("\\newpage", "page-break"),
            ("~~~{r}\n#| echo: fenced\n1\n~~~", "~~~{r}"),
            (":::: {.columns}\n::: {.column}\nBody\n:::\n::::", "<p>Body</p>"),
            ("::: {.panel-tabset}\n## Tab\nBody\n:::", "Tab"),
            ("::: {.column-margin}\nMargin\n:::", "Margin"),
            ("::: {.aside}\nAside\n:::", "Aside"),
            ("[A]{.underline}", "class=\"underline\""),
            ("[A]{.mark}", "class=\"mark\""),
            ("[A]{.custom}", "class=\"custom\""),
            ("[]{#anchor}", "id=\"anchor\""),
            ("~~~{r}\n%%| output: false\n42\n~~~", "42"),
        ])
    func paperSyntax(source: String, expected: String) {
        #expect(ComputationalMarkdown.convert(source).body.contains(expected))
    }

    @Test(
        "紙から除く指定をコードや式の本文と取り違えない",
        arguments: [
            ("---\ndate: last-modified\n---\nDaily", "last-modified"),
            ("---\ndate: \"`r Sys.Date()`\"\n---\nDaily", "Sys.Date"),
            ("~~~{=latex}\nsecret\n~~~", "secret"),
            ("~~~{r, results='hide'}\nx\n~~~", "chunk-result-note"),
            ("~~~{r setup}\nx\n~~~", "chunk-result-note"),
            ("~~~{r}\n#| code-fold: true\n#| warning: false\n42\n~~~", "#|"),
            ("::: {.content-hidden when-format=\"pdf\"}\nsecret\n:::", "secret"),
            ("::: {.content-visible unless-format=\"pdf\"}\nsecret\n:::", "secret"),
            ("::: {.callout-important title=\"Take care\" icon=false}\nBody\n:::", "callout-icon"),
            ("Before `@fig-a`\n\n![X](a.png){#fig-a}", "href=\"#fig-a\""),
            ("~~~md\n{{< include secret >}}\n~~~", "computational-note"),
            ("`r x * y * z`", "<em>"),
        ])
    func omissions(source: String, absent: String) {
        #expect(!ComputationalMarkdown.convert(source).body.contains(absent))
    }

    @Test("著者のインラインマップから名前だけを読む")
    func inlineAuthors() {
        let html = ComputationalMarkdown.convert("---\nauthor: [{name: 'A, B', id: 1}, {name: C}]\n---").body
        #expect(html.contains("A, B, C"))
        #expect(!html.contains("name:"))
    }

    @Test("異なる図には別の番号を付け表は一から数える")
    func counters() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            lang: ja
            ---
            @fig-b [@tbl-a]
            ~~~{r, fig.cap="最初"}
            1
            ~~~
            ~~~{r}
            #| label: fig-b
            #| fig-cap: 次
            2
            ~~~
            ~~~{r}
            #| label: tbl-a
            #| tbl-cap: 表題
            3
            ~~~
            """
        ).body
        #expect(html.contains(">図 2</a>"))
        #expect(html.contains(">表 1</a>"))
        #expect(html.components(separatedBy: "chunk-result-note").count == 4)
    }

    @Test("コードを適切な言語で色付けし静的なコードに結果枠を付けない", arguments: ["r", "julia", "python", "bash", "sql"])
    func highlighting(language: String) {
        let html = ComputationalMarkdown.convert("~~~{.\(language)}\n123\n~~~").body
        #expect(html.contains("language-\(language) hl"))
        #expect(!html.contains("chunk-result-note"))
    }

    @Test("目次にない見出しでも本文とアンカーを残す")
    func unlistedDocument() {
        let html = ComputationalMarkdown.convert("---\ntoc: true\n---\n# First\n## Extra {#extra .unlisted}").body
        #expect(html.contains("id=\"extra\""))
        #expect(!html.contains("href=\"#extra\""))
    }

    @Test("通常のMarkdownでも計算文書でも静的なRコードを色付けする")
    func staticListing() {
        let source = "~~~r\nprint(42)\n~~~"
        #expect(MarkdownConverter.convert(source).body.contains("class=\"language-r hl\""))
        #expect(ComputationalMarkdown.convert(source).body.contains("class=\"language-r hl\""))
    }
}
