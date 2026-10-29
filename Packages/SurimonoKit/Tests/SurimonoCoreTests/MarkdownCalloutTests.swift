import Testing

@testable import SurimonoCore

struct MarkdownCalloutTests {
    @Test("コロン囲みは種類と表題と本文を出力する")
    func colon() {
        let result = MarkdownConverter.convert(":::warning 気をつける <script>\n# 見出し\n\n**本文**\n:::")
        #expect(result.title == "見出し")
        #expect(result.body.contains("class=\"callout callout-warning\" data-callout=\"warning\""))
        #expect(result.body.contains("<p class=\"callout-title\">気をつける &lt;script&gt;</p>"))
        #expect(result.body.contains("<strong>本文</strong>"))
    }

    @Test(
        "別名を共通の見た目にし既定の表題を付ける",
        arguments: [
            ("info", "note", "Info"), ("done", "tip", "Done"), ("example", "important", "Example"),
            ("faq", "warning", "Faq"), ("bug", "danger", "Bug"), ("cite", "quote", "Cite"),
            ("custom", "neutral", "Custom"), ("details", "neutral", "Details"),
        ])
    func styles(type: String, style: String, title: String) {
        let body = MarkdownConverter.convert(":::\(type)\n本文\n:::").body
        #expect(body.contains("callout-\(style)\" data-callout=\"\(type)\""))
        #expect(body.contains("class=\"callout-title\">\(title)</p>"))
    }

    @Test("Zennのメッセージには表題を付けずalertを警告にする")
    func zenn() {
        for (marker, style, type) in [("message", "note", "message"), ("message alert", "danger", "alert")] {
            let body = MarkdownConverter.convert(":::\(marker)\n本文\n:::").body
            #expect(body.contains("callout-\(style)\" data-callout=\"\(type)\""))
            #expect(!body.contains("callout-title"))
        }
    }

    @Test("囲みを入れ子にでき未終了の囲みも閉じる")
    func nested() {
        let body = MarkdownConverter.convert("::::details 出力\n:::tip\n本文\n:::\n::::\n:::note\n最後").body
        #expect(body.components(separatedBy: "</div>").count == 4)
        #expect(body.contains("class=\"callout-title\">出力</p>"))
        #expect(!body.contains("<details"))
    }

    @Test("コードと深いインデントのコロンは変換しない", arguments: ["```", "~~~~"])
    func codeFence(fence: String) {
        let body = MarkdownConverter.convert("\(fence)\n:::note\n\(fence)\n\n    :::tip").body
        #expect(!body.contains("class=\"callout"))
        #expect(body.contains(":::note"))
        #expect(body.contains(":::tip"))
    }

    @Test("囲みの中のリストと表とコードを通常どおり解析する")
    func markdownInside() {
        let body = MarkdownConverter.convert(
            ":::note\n- 項目\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n:::"
        ).body
        #expect(body.contains("<ul>"))
        #expect(body.contains("<table>"))
        #expect(body.contains("language-swift hl"))
    }

    @Test("引用の表題のインライン書式と本文を保持する")
    func quoteTitle() {
        let body = MarkdownConverter.convert("> [!tip] **太字**の表題\n> 本文\n> 次の行").body
        #expect(body.contains("<p class=\"callout-title\"><strong>太字</strong>の表題</p>"))
        #expect(body.contains("<p>本文\n次の行</p>"))
        #expect(!body.contains("[!tip]"))
    }

    @Test("引用の既定表題と折りたたみ記号と空本文を扱う", arguments: ["", "-", "+"])
    func quoteMarker(suffix: String) {
        let body = MarkdownConverter.convert("> [!NOTE]\(suffix)").body
        #expect(body.contains("class=\"callout-title\">Note</p>"))
        #expect(!body.contains("<blockquote>"))
    }

    @Test("引用の囲みも再帰し通常の引用は変えない")
    func nestedQuote() {
        let body = MarkdownConverter.convert("> [!unknown]\n> outer\n>\n>> [!faq]-\n>> inner").body
        #expect(body.contains("callout-neutral"))
        #expect(body.contains("callout-warning"))
        #expect(MarkdownConverter.convert("> 普通").body == "<blockquote><p>普通</p>\n</blockquote>\n")
    }

    @Test("コードの既存クラスを保ち未知の言語と無指定は変更しない")
    func codeIntegration() {
        #expect(MarkdownConverter.convert("```JS\nconst x = 1\n```").body.contains("language-JS hl"))
        #expect(
            MarkdownConverter.convert("```unknown\n<&\n```").body
                == "<pre><code class=\"language-unknown\">&lt;&amp;\n</code></pre>\n")
        #expect(MarkdownConverter.convert("```\n<&\n```").body == "<pre><code>&lt;&amp;\n</code></pre>\n")
        #expect(
            OrgConverter.convert("#+BEGIN_SRC swift\nlet x = 1\n#+END_SRC").body.contains(
                "<span class=\"hl-keyword\">let</span>"))
    }
}

extension MarkdownCalloutTests {
    @Test("囲みより短い終端は内側を閉じない")
    func shortCloser() {
        let body = MarkdownConverter.convert("::::note\n:::tip\n内側\n:::\n外側\n:::\n最後\n::::").body
        #expect(body.components(separatedBy: "</div>").count == 3)
        #expect(body.contains(":::"))
    }

    @Test(
        "フェンスの終端は同じ文字と長さと行全体で判定する",
        arguments: [
            "````\n```\n:::note\n~~~\n````", "~~~\n~~~ trailing\n:::note\n~~~", "```\n:::note",
        ])
    func fenceBoundaries(source: String) {
        #expect(!MarkdownConverter.convert(source).body.contains("class=\"callout"))
    }

    @Test("囲み内の未終了コードも生成HTMLを本文へ混ぜずに閉じる")
    func unfinishedCodeInside() {
        let body = MarkdownConverter.convert(":::note\n```\ncode").body
        #expect(body.contains("<pre><code>code\n</code></pre>"))
        #expect(body.hasSuffix("</div>\n"))
        #expect(!body.contains("&lt;/div&gt;"))
    }

    @Test("front matterと最初の見出しの表題を保持する")
    func frontMatter() {
        let result = MarkdownConverter.convert("---\ntitle: 文書の表題\n---\n:::note\n# 見出し\n本文\n:::")
        #expect(result.title == "文書の表題")
        #expect(result.body.contains("callout-note"))
        #expect(!result.body.contains("title:"))
    }

    @Test(
        "不正なマーカーと先頭が段落でない引用は変換しない",
        arguments: [
            "> [!123]", "> [!bad type]", "> **[!note]**", "> # [!NOTE]", "> plain [!NOTE]",
        ])
    func ordinaryQuotes(source: String) {
        #expect(MarkdownConverter.convert(source).body.hasPrefix("<blockquote>"))
    }

    @Test("三文字までのインデントで囲めるが四文字とタブはコードになる")
    func indentation() {
        #expect(MarkdownConverter.convert("   :::note\n本文\n   :::").body.contains("callout-note"))
        for source in ["    :::note", "\t:::note"] {
            #expect(!MarkdownConverter.convert(source).body.contains("callout-note"))
        }
    }
}

extension MarkdownCalloutTests {
    @Test(
        "リスト内のコードフェンスではコロンを変換しない",
        arguments: [
            "- ```\n  :::note\n  ```", "1. ~~~\n   :::note\n   ~~~", "- 項目\n\n  ```\n  :::note\n  ```",
            "- ```\n  :::note\n     ```\n\n:::tip\n外側\n:::",
        ])
    func listFence(source: String) {
        let body = MarkdownConverter.convert(source).body
        #expect(body.contains(":::note"))
        #expect(!body.contains("data-callout=\"note\""))
        if source.contains(":::tip") { #expect(body.contains("data-callout=\"tip\"")) }
    }

    @Test("リストの外へ出たら未終了フェンスの影響を残さない")
    func listFenceDedent() {
        let body = MarkdownConverter.convert("- ```\n  :::note\n\n:::tip\n外側\n:::").body
        #expect(body.contains(":::note"))
        #expect(body.contains("callout-tip"))
    }
}

extension MarkdownCalloutTests {
    @Test(
        "リスト本文に字下げした囲み記法はリストを分断しない",
        arguments: [
            ("- item\n\n  :::note\n  text\n  :::\n\n- next", "ul"),
            ("1. item\n\n   :::note\n   text\n   :::\n\n2. next", "ol"),
        ])
    func indentedListCallout(source: String, tag: String) {
        let body = MarkdownConverter.convert(source).body
        #expect(!body.contains("callout-"))
        #expect(body.components(separatedBy: "<\(tag)").count == 2)
        #expect(body.contains(":::note"))
        #expect(body.contains("<li><p>next</p>"))
    }

    @Test("引用記号の後のコロン囲みはそのまま引用にする")
    func quotedColonFence() {
        let body = MarkdownConverter.convert("> :::note\n> text\n> :::").body
        #expect(body == "<blockquote><p>:::note\ntext\n:::</p>\n</blockquote>\n")
    }

    @Test(
        "既存HTMLブロック内の囲み記法を原文のまま残す",
        arguments: [
            "<pre>\n:::note\ntext\n:::\n</pre>",
            "<!--\n:::note\ntext\n:::\n-->",
            "<div>\n:::note\ntext\n:::\n</div>",
        ])
    func htmlBlockCallout(source: String) {
        #expect(MarkdownConverter.convert(source).body == source + "\n")
    }

    @Test("空行で独立した参照定義の表題の囲み記法を変更しない")
    func referenceTitleCallout() {
        let body = MarkdownConverter.convert("[label]: /url \"first\n:::note\nlast\"\n\n[label]").body
        #expect(body == "<p><a href=\"/url\" title=\"first\n:::note\nlast\">label</a></p>\n")
    }

    @Test("囲み内リストの遅延継続より字下げなしの閉じフェンスを優先する")
    func listLazyClosingFence() {
        let body = MarkdownConverter.convert(":::note\n- item\n:::\n\nafter").body
        #expect(body.contains("callout-note"))
        #expect(body.contains("</ul>\n</div>\n<p>after</p>"))
        #expect(!body.contains(":::"))
    }

    @Test("囲み内引用の遅延継続より字下げなしの閉じフェンスを優先する")
    func quoteLazyClosingFence() {
        let body = MarkdownConverter.convert(":::note\n> quote\n:::\n\nafter").body
        #expect(body.contains("callout-note"))
        #expect(body.contains("</blockquote>\n</div>\n<p>after</p>"))
        #expect(!body.contains(":::"))
    }

    @Test("引用の遅延継続より字下げなしの開始フェンスを優先する")
    func quoteLazyOpeningFence() {
        let body = MarkdownConverter.convert("> quote\n:::message\nbody\n:::").body
        #expect(body.hasPrefix("<blockquote><p>quote</p>\n</blockquote>\n<div class=\"callout callout-note\""))
        #expect(body.contains("<p>body</p>\n</div>"))
    }
}

extension MarkdownCalloutTests {
    @Test("入れ子リストでは内側の本文開始列で遅延継続を判定する")
    func nestedListLazyClosingFence() {
        let body = MarkdownConverter.convert(":::note\n- parent\n  - child\n  :::\n\nafter").body
        #expect(body.contains("callout-note"))
        #expect(body.hasSuffix("</div>\n<p>after</p>\n"))
        #expect(!body.contains(":::"))
    }

    @Test(
        "コードとHTMLの中の終端記法は外側の囲みを閉じない",
        arguments: [
            "<pre>\n:::\n</pre>", "<!--\n:::\n-->", "```\n:::\n```",
        ])
    func protectedClosingFence(block: String) {
        let body = MarkdownConverter.convert(":::note\n" + block + "\n\ninside\n:::\n\nafter").body
        #expect(body.contains(":::"))
        #expect(body.contains("<p>inside</p>\n</div>\n<p>after</p>"))
        #expect(body.components(separatedBy: "</div>").count == 2)
    }

    @Test(
        "末尾のコードの種類によらず補った囲み終端をコードへ混ぜない",
        arguments: [
            "~~~\ncode\n\n", "```", "```\ncode\n```\n\n", "- ```\n  code",
            "> ```\n> code", "\n    ```\n    code",
        ])
    func terminalCodeRecovery(block: String) {
        let body = MarkdownConverter.convert(":::note\n" + block).body
        #expect(body.hasSuffix("</div>\n"))
        #expect(!body.contains("&lt;/div&gt;"))
        #expect(body.components(separatedBy: "<pre>").count == 2)
    }
}

extension MarkdownCalloutTests {
    @Test(
        "字下げコードで始まるリスト本文の囲み記法は変換しない",
        arguments: [
            ("-     code\n\n  :::note\n  text\n  :::\n\n- next", "ul"),
            ("1.     code\n\n   :::note\n   text\n   :::\n\n2. next", "ol"),
            ("-\t  code\n\n  :::note\n  text\n  :::\n\n- next", "ul"),
            ("1)\t   code\n\n   :::note\n   text\n   :::\n\n2) next", "ol"),
        ])
    func codeFirstListBody(source: String, tag: String) {
        let body = MarkdownConverter.convert(source).body
        #expect(!body.contains("callout-"))
        #expect(body.components(separatedBy: "<\(tag)").count == 2)
        #expect(body.components(separatedBy: "<li>").count == 3)
        #expect(body.contains("<pre><code>code\n</code></pre>"))
        #expect(body.contains("<p>:::note\ntext\n:::</p>"))
        #expect(body.contains("<li><p>next</p>"))
    }

    @Test(
        "空の開始行の空白数によらずリスト本文を保護する",
        arguments: [
            "-", "-    ", "-\t", "-     ",
        ])
    func emptyListMarkerBody(marker: String) {
        let body = MarkdownConverter.convert(marker + "\n  :::note\n  text\n  :::\n\n- next").body
        #expect(!body.contains("callout-"))
        #expect(body.components(separatedBy: "<ul>").count == 2)
        #expect(body.components(separatedBy: "<li>").count == 3)
    }

    @Test("マーカー直後のタブを四列区切りに展開して本文位置を求める")
    func markerTabStop() {
        let body = MarkdownConverter.convert("-\titem\n    :::note\n    text\n    :::").body
        #expect(!body.contains("callout-"))
        #expect(body.contains(":::note"))
        let lazy = MarkdownConverter.convert("-\titem\n   :::note\nbody\n:::").body
        #expect(lazy.contains("callout-note"))
    }

    @Test(
        "本文へ続く参照定義の字下げなしのコロンはmarkdown-it-containerと同じく囲みとして扱う",
        arguments: ["/url", "</url>"])
    func referenceTitleWithoutBlankLine(destination: String) {
        let definition = "[label]: \(destination) \"first\n:::note\nlast\"\n"
        let body = MarkdownConverter.convert(definition + "[label]").body
        #expect(body.contains("<div class=\"callout callout-note\" data-callout=\"note\">"))
        #expect(body.contains("<p>last&quot;\n[label]</p>\n</div>"))
        #expect(!body.contains("href=\"/url\""))
        #expect(
            MarkdownConverter.convert(definition + "\n[label]").body
                == "<p><a href=\"/url\" title=\"first\n:::note\nlast\">label</a></p>\n")
    }

    @Test("参照定義を打ち切る囲みの扱いは先行する文書の量に依存しない", arguments: [0, 1_000])
    func referenceFenceIndependentOfDocumentSize(paragraphs: Int) {
        let prefix = String(repeating: "前に置いた段落です。\n\n", count: paragraphs)
        let source = prefix + "[label]: /url \"first\n:::note\nlast\"\n[label]"
        let processed = MarkdownCallouts.preprocess(source.components(separatedBy: "\n"))
        #expect(processed.hasPrefix(prefix + "[label]: /url \"first\n"))
        #expect(processed.components(separatedBy: "<div ").count == 2)
        #expect(processed.contains("callout-note"))
        #expect(processed.hasSuffix("last\"\n[label]\n\n</div>\n"))
    }

    @Test(
        "本文の後の囲みフェンスは段落の遅延継続より優先する",
        arguments: [
            "本文", "[label]: /url\n[label]",
        ])
    func paragraphLazyOpeningFence(prefix: String) {
        let body = MarkdownConverter.convert(prefix + "\n:::note\ninside\n:::\n\nafter").body
        #expect(body.contains("</p>\n<div class=\"callout callout-note\""))
        #expect(body.contains("<p>inside</p>\n</div>\n<p>after</p>"))
    }
}

extension MarkdownCalloutTests {
    @Test("同じ項目内の字下げした参照定義一万組を前処理する", .timeLimit(.minutes(1)))
    func manyIndentedReferenceParagraphs() {
        checkManyReferenceParagraphs(indentation: "  ")
    }

    @Test("同じ項目内の遅延継続の参照定義一万組を前処理する", .timeLimit(.minutes(1)))
    func manyLazyReferenceParagraphs() {
        checkManyReferenceParagraphs(indentation: "")
    }

    private func checkManyReferenceParagraphs(indentation: String) {
        let paragraph = "  [r]: /url \"first\n\(indentation):::note\n  last\"\n  body\n\n"
        let source = "- item\n\n" + String(repeating: paragraph, count: 10_000)
        let processed = MarkdownCallouts.preprocess(source.components(separatedBy: "\n"))
        if indentation.isEmpty {
            #expect(processed.components(separatedBy: "<div ").count == 10_001)
            #expect(processed.components(separatedBy: "</div>").count == 10_001)
            #expect(processed.components(separatedBy: "  body").count == 10_001)
        } else {
            #expect(processed == source)
        }
    }

    @Test("参照定義を持つ一万項目のリストを前処理する", .timeLimit(.minutes(1)))
    func manyReferenceDefinitions() {
        checkManyReferenceDefinitions(hasFence: false)
    }

    @Test("表題にコロンを含む参照定義を持つ一万項目のリストを前処理する", .timeLimit(.minutes(1)))
    func manyReferenceDefinitionsWithFence() {
        checkManyReferenceDefinitions(hasFence: true)
    }

    private func checkManyReferenceDefinitions(hasFence: Bool) {
        let title = hasFence ? " \"first\n  :::note\n  last\"" : ""
        let source = String(repeating: "- [r]: /url\(title)\n  body\n\n", count: 10_000)
        #expect(MarkdownCallouts.preprocess(source.components(separatedBy: "\n")) == source)
    }

    @Test("参照定義を持つ複数項目は一つのリストとしてHTMLにする", arguments: [false, true])
    func referenceListHTML(hasFence: Bool) {
        let title = hasFence ? " \"first\n  :::note\n  last\"" : ""
        let body = MarkdownConverter.convert(String(repeating: "- [r]: /url\(title)\n  body\n\n", count: 3)).body
        #expect(!body.contains("callout-"))
        #expect(body.components(separatedBy: "<ul>").count == 2)
        #expect(body.components(separatedBy: "<li>").count == 4)
        #expect(body.components(separatedBy: "<p>body</p>").count == 4)
    }

    @Test("同じ項目内の参照定義は字下げに応じて囲みのHTMLになる", arguments: ["  ", ""])
    func referenceParagraphsHTML(indentation: String) {
        let paragraph = "  [r]: /url \"first\n\(indentation):::note\n  last\"\n  body\n\n"
        let body = MarkdownConverter.convert("- item\n\n" + String(repeating: paragraph, count: 3)).body
        #expect(body.components(separatedBy: "body").count == 4)
        if indentation.isEmpty {
            #expect(body.components(separatedBy: "<div ").count == 4)
            #expect(body.components(separatedBy: "</div>").count == 4)
        } else {
            #expect(!body.contains("callout-"))
            #expect(body.components(separatedBy: "<li>").count == 2)
        }
    }

    @Test("先行項目があっても入れ子のリストの参照定義を保持する")
    func nestedReferenceAfterSibling() {
        let source = """
            - previous

            - outer
              - [label]: /url "first
                :::note
                last"
                [label]

            - next
            """
        let body = MarkdownConverter.convert(source).body
        #expect(!body.contains("callout-"))
        #expect(body.contains("<a href=\"/url\" title=\"first\n:::note\nlast\">label</a>"))
        #expect(body.components(separatedBy: "<ul>").count == 3)
        #expect(body.components(separatedBy: "<li>").count == 5)
    }

    @Test(
        "参照定義を打ち切る囲みは後続インラインの種類と行数に依存しない",
        arguments: [
            "日本語", "**bold**", "`code`", "![label]", "<em>text</em>", "one\nsecond", "`one\ntwo`", "[label]\n[label]",
        ])
    func referencePrefixBeforeInlineContent(suffix: String) {
        let definition = "[label]: </url> \"first\n:::note\nlast\"\n"
        let body = MarkdownConverter.convert(definition + suffix).body
        #expect(body.contains("callout-note"))
        #expect(body.hasSuffix("</div>\n"))
        #expect(!MarkdownConverter.convert(definition + "\n" + suffix).body.contains("callout-"))
    }

    @Test(
        "独立した複数の参照定義と明示的な引用やリスト本文の参照定義を保持する",
        arguments: [
            "[other]: /other\n[label]: /url \"first\n:::note\nlast\"\n\n[label]",
            "> [label]: /url \"first\n> :::note\n> last\"\n> [label]",
            "- [label]: /url \"first\n  :::note\n  last\"\n  [label]",
        ])
    func referenceDefinitionsInContext(source: String) {
        let body = MarkdownConverter.convert(source).body
        #expect(body.contains("<a href=\"/url\" title=\"first\n:::note\nlast\">label</a>"))
        #expect(!body.contains("callout-"))
    }
}
