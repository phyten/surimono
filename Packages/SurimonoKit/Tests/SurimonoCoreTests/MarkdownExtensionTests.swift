import SurimonoCore
import Testing

struct MarkdownExtensionTests {
    private func body(_ markdown: String) -> String { MarkdownConverter.convert(markdown).body }

    @Test("脚注は最初に参照した順に番号を振り、定義を本文から外して末尾にまとめる")
    func footnotes() {
        let html = body("本文[^a]と[^b]。\n\n[^b]: 二つ目\n[^a]: 一つ目\n    続きの行\n\n後の段落")
        #expect(html.contains("<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>と"))
        #expect(html.contains("<a href=\"#fn-2\" id=\"fnref-2\">2</a>"))
        #expect(html.contains("<li id=\"fn-1\"><p>一つ目\n続きの行</p>\n</li>"))
        #expect(html.contains("<li id=\"fn-2\"><p>二つ目</p>\n</li>"))
        #expect(html.contains("<p>後の段落</p>"))
        #expect(!html.contains("[^"))
        #expect(html.hasSuffix("</ol>\n</section>\n"))
    }

    @Test("同じ脚注を二度参照すると番号は同じで、二度目の参照には別の id を付ける")
    func repeatedFootnote() {
        let html = body("一[^n] 二[^N]\n\n[^n]: 注")
        #expect(html.contains("id=\"fnref-1\">1</a>"))
        #expect(html.contains("id=\"fnref-1-2\">1</a>"))
        #expect(html.components(separatedBy: "<li id=").count == 2)
    }

    @Test("定義のない脚注の参照は書いたとおりに残す")
    func undefinedFootnote() {
        let html = body("参照[^x]だけ")
        #expect(html.contains("参照[^x]だけ"))
        #expect(!html.contains("footnotes"))
    }

    @Test("コードスパンとコードブロックの中は拡張記法として読まない")
    func codeIsLeftAlone() {
        let html = body("`[^a] ==x==` と ==y==\n\n```\n==z== [^a] {漢|かん}\n```\n\n[^a]: 注")
        #expect(html.contains("<code>[^a] ==x==</code> と <mark>y</mark>"))
        #expect(html.contains("==z== [^a] {漢|かん}"))
        #expect(!html.contains("footnotes"))
    }

    @Test("ハイライト・上付き・下付きを出し、二本の波線は取り消し線のままにする")
    func highlightSuperscriptSubscript() {
        let html = body("==重要== 2^10^ H~2~O ~~消す~~ ==**太字**==")
        #expect(html.contains("<mark>重要</mark>"))
        #expect(html.contains("2<sup>10</sup>"))
        #expect(html.contains("H<sub>2</sub>O"))
        #expect(html.contains("<del>消す</del>"))
        #expect(html.contains("<mark><strong>太字</strong></mark>"))
    }

    @Test("空白を挟んだ等号やべき乗の式は書き換えない")
    func comparisonsStayAsWritten() {
        let html = body("a == b と x^2 + y^2")
        #expect(html.contains("a == b と x^2 + y^2"))
    }

    @Test("リンク先と URL の中の波線は下付きにしない")
    func urlsStayAsWritten() {
        let html = body("[家](https://example.com/~user/~x) と https://example.com/~a/~b")
        #expect(html.contains("href=\"https://example.com/~user/~x\""))
        #expect(html.contains("https://example.com/~a/~b"))
        #expect(!html.contains("<sub>"))
    }

    @Test("ルビは単語ごとにも一文字ずつにも付けられ、表の中でも列を分けない")
    func ruby() {
        let html = body("{漢字|かんじ}と{東京|とう|きょう}\n\n| 語 |\n| - |\n| {振|ふ} |")
        #expect(html.contains("<ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>と"))
        #expect(html.contains("<ruby>東<rp>(</rp><rt>とう</rt><rp>)</rp>京<rp>(</rp><rt>きょう</rt><rp>)</rp></ruby>"))
        #expect(html.contains("<td><ruby>振<rp>(</rp><rt>ふ</rt><rp>)</rp></ruby></td>"))
    }

    @Test("絵文字の短縮名を絵文字にし、知らない名前とコードの中は残す")
    func emoji() {
        let html = body(":tada: と :+1: と :not_an_emoji: と `:smile:`")
        #expect(html.contains("🎉 と 👍 と :not_an_emoji: と <code>:smile:</code>"))
    }

    @Test("語の次の行がコロンで始まると定義リストになり、コロンのない行は次の語になる")
    func compactDefinitionList() {
        let html = body("りんご\n: 赤い *果物*\n: 会社の名前\nみかん\n: 冬の果物")
        #expect(
            html
                == "<dl>\n<dt>りんご</dt>\n<dd>赤い <em>果物</em></dd>\n<dd>会社の名前</dd>\n<dt>みかん</dt>\n<dd>冬の果物</dd>\n</dl>\n"
        )
    }

    @Test("語の段落のあとにコロンで始まる段落が続いても定義リストになる")
    func looseDefinitionList() {
        let html = body("りんご\n\n: 赤い果物\n\n: 会社の\n名前\n\n次の段落")
        #expect(
            html.hasPrefix("<dl>\n<dt>りんご</dt>\n<dd>赤い果物</dd>\n<dd>会社の\n名前</dd>\n</dl>\n<p>次の段落</p>"))
    }

    @Test("見出しに GitHub と同じ ID を付け、重複には番号を足し、{#id} はその ID にして文字から外す")
    func headingIDs() {
        let html = body("# 見出し\n## Hello, World!\n## Hello, World!\n## 名前 {#custom}")
        #expect(html.contains("<h1 id=\"見出し\">見出し</h1>"))
        #expect(html.contains("<h2 id=\"hello-world\">Hello, World!</h2>"))
        #expect(html.contains("<h2 id=\"hello-world-1\">Hello, World!</h2>"))
        #expect(html.contains("<h2 id=\"custom\">名前</h2>"))
    }

    @Test("[TOC] の段落を見出しへのリンクの入れ子にし、一つだけの表題は外す")
    func tableOfContents() {
        let html = body("# 表題\n\n[TOC]\n\n## 一\n### 一の一\n## 二")
        #expect(
            html.contains(
                "<nav class=\"toc\"><ul><li><a href=\"#一\">一</a><ul><li><a href=\"#一の一\">一の一</a></li></ul></li><li><a href=\"#二\">二</a></li></ul></nav>"
            ))
        #expect(!html.contains("[TOC]"))
        #expect(MarkdownConverter.convert("[[_TOC_]]\n\n## 一\n## 二").body.contains("<nav class=\"toc\">"))
    }

    @Test("表題には脚注の参照と {#id} を含めない")
    func titleWithoutExtensions() {
        #expect(MarkdownConverter.convert("# 本[^1] {#top}\n\n[^1]: 注").title == "本")
    }
}

struct MarkdownExtensionBoundaryTests {
    private func body(_ markdown: String) -> String { MarkdownConverter.convert(markdown).body }

    @Test("複数行にまたがるコードスパンの中は書き換えず、脚注の定義とも読まない")
    func multilineCodeSpan() {
        let html = body("`first\n==x==\n[^n]: 注 last` と ==y==\n\n参照[^n]")
        #expect(html.contains("<code>first ==x== [^n]: 注 last</code> と <mark>y</mark>"))
        #expect(html.contains("参照[^n]"))
    }

    @Test("参照形式のリンクの定義は書き換えず、リンク先を保つ")
    func referenceDefinition() {
        let html = body("[資料][doc] と H~2~O\n\n[doc]: ./~draft~/guide.md\n  \"題 ~x~\"")
        #expect(html.contains("<a href=\"./~draft~/guide.md\" title=\"題 ~x~\">資料</a>"))
        #expect(html.contains("H<sub>2</sub>O"))
    }

    @Test(
        "宛先が次の行・引用やリストの中・複数行やエスケープを含むタイトルの参照定義も書き換えない",
        arguments: [
            ("[資料][doc]\n\n[doc]:\n  ./~draft~/guide.md", "<a href=\"./~draft~/guide.md\">資料</a>"),
            ("> [資料][doc]\n>\n> [doc]: ./~draft~/guide.md", "<a href=\"./~draft~/guide.md\">資料</a>"),
            (
                "[資料][doc]\n\n[doc]: ./guide.md \"first\n~draft~ last\"",
                "<a href=\"./guide.md\" title=\"first\n~draft~ last\">資料</a>"
            ),
            (
                "[資料][doc]\n\n[doc]: ./guide.md \"first \\\"quoted\\\"\n~draft~ last\"",
                "<a href=\"./guide.md\" title=\"first &quot;quoted&quot;\n~draft~ last\">資料</a>"
            ),
            ("[資料][doc]\n\n- [doc]: ./~draft~/guide.md", "<a href=\"./~draft~/guide.md\">資料</a>"),
            ("[資料][doc]\n\n1. [doc]: ./~draft~/guide.md", "<a href=\"./~draft~/guide.md\">資料</a>"),
        ])
    func referenceDefinitionForms(markdown: String, link: String) {
        let html = body(markdown)
        #expect(html.contains(link))
        #expect(!html.contains("<sub>"))
    }

    @Test("URL の中の絵文字の短縮名は変えず、リンク先を保つ")
    func emojiInsideURL() {
        let html = body("https://example.com/:smile:/page と :smile:")
        #expect(html.contains("href=\"https://example.com/:smile:/page\""))
        #expect(html.contains(">https://example.com/:smile:/page</a> と 😄"))
    }

    @Test("エスケープや文字参照で書いたコロンは定義リストにしない")
    func escapedColonIsNotADefinition() {
        #expect(!body("説明\n\\: これは定義ではない").contains("<dl>"))
        #expect(!body("説明\n&#58; これも定義ではない").contains("<dl>"))
        #expect(!body("説明\n\n\\: 段落でも同じ").contains("<dl>"))
    }

    @Test("コロン囲みの表題は素の文字のままにし、生成した HTML を見せない")
    func calloutTitleStaysPlain() {
        let html = body(":::note ==重要==\n本文は ==強調== する\n:::")
        #expect(html.contains("<p class=\"callout-title\">==重要==</p>"))
        #expect(html.contains("本文は <mark>強調</mark> する"))
    }

    @Test("脚注のあとの空行が続いても、字下げした行が来れば同じ脚注に続ける")
    func footnoteAcrossBlankLines() {
        let html = body("本文[^a]\n\n[^a]: 一段落目\n\n\n\n    二段落目\n\n次の段落")
        #expect(html.contains("<li id=\"fn-1\"><p>一段落目</p>\n<p>二段落目</p>\n</li>"))
        #expect(html.contains("<p>次の段落</p>"))
    }
}
