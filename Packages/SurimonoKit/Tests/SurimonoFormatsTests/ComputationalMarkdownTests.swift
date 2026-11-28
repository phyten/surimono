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
            ("Reference @sec-end\n\n# End {#sec-end}", "End</a>", "@sec-end"),
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
            ("sec-a", "# Chapter {#sec-a}", "Chapter"),
            ("eq-a", "$$\nx^2\n$$ {#eq-a}", "Equation 1"),
            ("thm-a", "::: {#thm-a}\nBody\n:::", "Theorem 1"),
            ("lem-a", "::: {#lem-a}\nBody\n:::", "Lemma 1"),
            ("def-a", "::: {#def-a}\nBody\n:::", "Definition 1"),
            ("exm-a", "::: {#exm-a}\nBody\n:::", "Example 1"),
        ])
    func reference(id: String, source: String, name: String) {
        let html = ComputationalMarkdown.convert("[@\(id)] [-@\(id)] @unknown\n\n" + source).body
        #expect(html.contains("<a href=\"#\(id)\">\(name)</a>"))
        #expect(html.contains("<a href=\"#\(id)\">\(id == "sec-a" ? name : "1")</a>"))
        #expect(html.contains("id=\"\(id)\""))
        #expect(html.contains("@unknown"))
    }

    @Test("bookdownのチャンク名を図番号に結びつけ、参照は番号だけを出す")
    func bookdown() {
        let html = ComputationalMarkdown.convert(
            "Figure \\@ref(fig:cars)\n\n~~~{r cars, fig.cap='Cars', results='show'}\nx\n~~~", format: .rMarkdown
        ).body
        #expect(html.contains("Figure <a href=\"#fig:cars\">1</a>"))
        #expect(html.contains("Figure 1 Cars"))
    }

    @Test("eval=FALSEのチャンクは図を作らず、bookdownの参照は??になって確認に出る")
    func bookdownUnresolved() {
        let fragment = ComputationalMarkdown.convert(
            "図 \\@ref(fig:plan) を見る。\n\n```{r plan, fig.cap='配置', eval=FALSE}\nplot(1)\n```", format: .rMarkdown)
        #expect(fragment.body.contains("図 <strong>??</strong> を見る。"))
        #expect(!fragment.body.contains("@ref"))
        #expect(!fragment.body.contains("<figure"))
        #expect(fragment.readingIssues == ["Unresolved cross-references: fig:plan"])
    }

    @Test("bookdownの表の題の(\\#tab:…)に番号を付けて参照できる")
    func bookdownTable() {
        let html = ComputationalMarkdown.convert(
            "Table \\@ref(tab:sizes) lists them.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nTable: (\\#tab:sizes) Sizes",
            format: .rMarkdown
        ).body
        #expect(html.contains("Table <a href=\"#tab:sizes\">1</a> lists them."))
        #expect(html.contains("<div id=\"tab:sizes\" class=\"table-caption\">Table 1 Sizes</div>"))
    }

    @Test("bookdownで見出しのIDを指す参照は節番号になる")
    func bookdownSection() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            output:
              html_document:
                number_sections: true
            ---
            # First

            # Methods {#methods}

            See Section \\@ref(methods).
            """, format: .rMarkdown
        ).body
        #expect(html.contains("See Section <a href=\"#methods\">2</a>."))
    }

    @Test("Quartoの種類の分かる参照が見つからなければ?@名前を太字で出し、引用らしい@は残す")
    func quartoUnresolved() {
        let fragment = ComputationalMarkdown.convert("See [@fig-none] and @smith2020.")
        #expect(fragment.body.contains("See <strong>?@fig-none</strong> and @smith2020."))
        #expect(fragment.readingIssues == ["Unresolved cross-references: fig-none"])
    }

    @Test(
        "コード・数式・リンク先の中の参照らしい文字は、そのまま残し確認にも出さない",
        arguments: [
            ("`begin\n\\@ref(fig:missing)\nend`", "\\@ref(fig:missing)"),
            ("<code>\\@ref(fig:missing)</code>", "<code>@ref(fig:missing)</code>"),
            ("[link](https://example.com/a(b)/@fig-missing)", "href=\"https://example.com/a(b)/@fig-missing\""),
            ("See [link].\n\n[link]: https://example.com/@fig-missing", "href=\"https://example.com/@fig-missing\""),
        ])
    func literalReferences(source: String, kept: String) {
        let fragment = ComputationalMarkdown.convert(source, format: .rMarkdown)
        #expect(fragment.body.contains(kept))
        #expect(!fragment.body.contains("??"))
        #expect(!fragment.body.contains("?@"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("数式の中の参照らしい文字は参照として数えない")
    func referenceInsideFormula() {
        let fragment = ComputationalMarkdown.convert(#"Inline \(\text{@fig-missing}\) here."#)
        #expect(!fragment.body.contains("?@fig-missing"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("Quartoの参照の形でない[@fig:key]は文献の引用として原文のまま残す")
    func colonCitation() {
        let fragment = ComputationalMarkdown.convert("See [@fig:smith2020].")
        #expect(fragment.body.contains("See [@fig:smith2020]."))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("見出しと同じ名前の文献の引用は、bookdownの参照があっても節へのリンクにしない")
    func citationNamedLikeHeading() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            output:
              html_document:
                number_sections: true
            ---
            # Methods {#methods}

            See Section \\@ref(methods). Citation [@methods].
            """, format: .rMarkdown
        ).body
        #expect(html.contains("See Section <a href=\"#methods\">1</a>. Citation [@methods]."))
    }

    @Test("Quartoの先頭を大文字にした参照も同じ図を指す")
    func capitalizedQuartoReference() {
        let html = ComputationalMarkdown.convert("@Fig-a shows it.\n\n![Paper](paper.png){#fig-a}").body
        #expect(html.contains("<a href=\"#fig-a\">Figure 1</a> shows it."))
    }

    @Test("bookdownの表の題は強調と参照を本文と同じに読む")
    func bookdownTableCaptionInline() {
        let fragment = ComputationalMarkdown.convert(
            """
            | A | B |
            |---|---|
            | 1 | 2 |

            Table: (\\#tab:t) **Sizes**; see Figure \\@ref(fig:later) and \\@ref(fig:missing)

            ```{r later, fig.cap='Later'}
            plot(1)
            ```
            """, format: .rMarkdown)
        #expect(
            fragment.body.contains(
                "<div id=\"tab:t\" class=\"table-caption\">Table 1 <strong>Sizes</strong>; see Figure "
                    + "<a href=\"#fig:later\">1</a> and <strong>??</strong></div>"))
        #expect(fragment.readingIssues == ["Unresolved cross-references: fig:missing"])
    }

    @Test(
        "bookdownで番号のない見出しを指す参照は、bookdownと同じく??になる",
        arguments: ["methods", "sec-methods"])
    func bookdownUnnumberedSection(id: String) {
        let fragment = ComputationalMarkdown.convert(
            "# Methods {#\(id)}\n\nSee \\@ref(\(id)).", format: .rMarkdown)
        #expect(fragment.body.contains("See <strong>??</strong>."))
        #expect(fragment.readingIssues == ["Unresolved cross-references: \(id)"])
    }

    @Test("複数行の\\[…\\]の中の参照らしい文字は参照として数えない")
    func referenceInsideDisplayFormula() {
        let fragment = ComputationalMarkdown.convert("Before.\n\n\\[\n\\text{@fig-missing}\n\\]\n\nAfter.")
        #expect(!fragment.body.contains("?@fig-missing"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("コードスパンの中に書いた<code>は、その外の参照を隠さない")
    func codeTagsInsideCodeSpans() {
        let html = ComputationalMarkdown.convert(
            "Use `<code>`; see @fig-a; close with `</code>`.\n\n![Paper](paper.png){#fig-a}"
        ).body
        #expect(html.contains("see <a href=\"#fig-a\">Figure 1</a>; close"))
    }

    @Test("bookdownでSetextの見出しの自動のIDを指す参照も節番号になる")
    func bookdownSetextSection() {
        let html = ComputationalMarkdown.convert(
            """
            ---
            output:
              html_document:
                number_sections: true
            ---
            Methods
            =======

            See Section \\@ref(methods).
            """, format: .rMarkdown
        ).body
        #expect(html.contains("See Section <a href=\"#methods\">1</a>."))
    }

    @Test("日本語と絵文字の後の脚注でも、<code>の中は原文のまま残り、外の参照は番号になる")
    func footnoteAfterWideCharacters() {
        let fragment = ComputationalMarkdown.convert(
            "図の説明😀^[<code>\\@ref(fig:missing)</code> と \\@ref(fig:cars)]。\n\n"
                + "~~~{r cars, fig.cap='Cars', results='show'}\nx\n~~~", format: .rMarkdown)
        #expect(fragment.body.contains("<code>@ref(fig:missing)</code>"))
        #expect(fragment.body.contains("と <a href=\"#fig:cars\">1</a>"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test(
        "表の題・脚注・属性付きのspanの中の<code>…</code>も参照として読まない",
        arguments: [
            "| x |\n|---|\n| 1 |\n\nTable: (\\#tab:t) Example <code>\\@ref(fig:missing)</code>",
            "Note^[<code>\\@ref(fig:missing)</code>].",
            "[<code>\\@ref(fig:missing)</code>]{.x}",
        ])
    func codeElementInsideNestedText(source: String) {
        let fragment = ComputationalMarkdown.convert(source, format: .rMarkdown)
        #expect(!fragment.body.contains("??"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test(
        "属性の値に>を含む<code>の中も参照として読まず、外の参照は解決する",
        arguments: [#"<code title="a > b">"#, #"<code title='a > b'>"#])
    func codeTagWithAngleInAttribute(tag: String) {
        let fragment = ComputationalMarkdown.convert(
            "Example: \(tag)\\@ref(fig:missing)</code> and Figure \\@ref(fig:cars).\n\n"
                + "~~~{r cars, fig.cap='Cars', results='show'}\nx\n~~~", format: .rMarkdown)
        #expect(!fragment.body.contains("??"))
        #expect(fragment.body.contains("and Figure <a href=\"#fig:cars\">1</a>."))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("段落の中で行をまたぐ<code>…</code>の中は参照として読まない")
    func codeElementOverLines() {
        let fragment = ComputationalMarkdown.convert(
            "Example: <code>\n\\@ref(fig:missing)\n</code>.", format: .rMarkdown)
        #expect(!fragment.body.contains("??"))
        #expect(fragment.readingIssues.isEmpty)
    }

    @Test("[@fig-key]はR Markdownでは文献の引用、Quartoでは相互参照として読む")
    func citationOrReferenceByFormat() {
        let rMarkdown = ComputationalMarkdown.convert(
            "See [@fig-smith2020].\n\n![Paper](paper.png){#fig-smith2020}", format: .rMarkdown)
        #expect(rMarkdown.body.contains("See [@fig-smith2020]."))
        #expect(rMarkdown.readingIssues.isEmpty)
        let quarto = ComputationalMarkdown.convert("See [@fig-smith2020].", format: .quarto)
        #expect(quarto.body.contains("See <strong>?@fig-smith2020</strong>."))
        #expect(quarto.readingIssues == ["Unresolved cross-references: fig-smith2020"])
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
