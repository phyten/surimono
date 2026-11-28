import Foundation
import Testing

@testable import SurimonoFormats

struct AsciiDocTests {
    @Test("JavaScriptCoreで表題・著者・版と宣言言語を読む")
    func title() throws {
        let doc = try AsciiDocConverter.convert("= Title\nPaper Team\nv1.0, 2026-01-01\n:lang: ja")
        #expect(doc.title == "Title")
        #expect(doc.language == "ja")
        for text in ["org-title-block", "Paper Team", "2026-01-01"] { #expect(doc.body.contains(text)) }
        #expect(try AsciiDocConverter.convert("= Title").language == nil)
    }

    @Test("並行した変換で別文書の表題が混ざらない")
    func concurrent() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    let document = try AsciiDocConverter.convert("= Title \(i)")
                    #expect(document.title == "Title \(i)")
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("5 MBを超える原文は通知とエスケープしたテキストにする")
    func limit() throws {
        let doc = try AsciiDocConverter.convert(String(repeating: "紙", count: 1_750_000) + "<ok>")
        #expect(doc.body.contains("surimono-plain"))
        #expect(doc.body.contains("5 MB"))
        #expect(doc.body.contains("&lt;ok&gt;"))
    }

    @Test("見出し・目次・相互参照が同じIDを使う")
    func outline() throws {
        let html = try AsciiDocConverter.convert("= Title\n:toc:\n:sectnums:\n\n[[intro]]\n== Intro\n\n<<intro>>").body
        for text in ["<nav class=\"toc\"", "id=\"intro\"", "href=\"#intro\"", "1. Intro"] {
            #expect(html.contains(text))
        }
    }

    @Test("図のブロックを既存の描画器へ渡す", arguments: ["mermaid", "plantuml", "graphviz", "dot"])
    func diagram(kind: String) throws {
        let cls = (kind == "dot" ? "graphviz" : kind) + "-block"
        for (style, fence) in [(kind, "----"), (kind, "...."), (kind, "--"), ("source," + kind, "----")] {
            let body = try AsciiDocConverter.convert("[\(style)]\n\(fence)\nA -> B\n\(fence)").body
            #expect(body.contains(cls))
            #expect(body.contains("A -&gt; B"))
        }
    }

    @Test("注意書きはMarkdownと同じ囲みになる", arguments: ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"])
    func admonition(label: String) throws {
        let body = try AsciiDocConverter.convert("\(label): Details").body
        #expect(body.contains("data-callout=\"\(label.lowercased())\""))
        #expect(body.contains("callout-title"))
        #expect(body.contains("Details"))
    }

    @Test("脚注は参照順で文末にまとめ戻りリンクを除く")
    func footnotes() throws {
        let body = try AsciiDocConverter.convert("First footnote:a[Alpha] next footnote:[Beta] again footnote:a[].")
            .body
        for text in ["footnote-ref", "<section class=\"footnotes\">", "id=\"fn-1\"", "id=\"fn-2\""] {
            #expect(body.contains(text))
        }
        #expect(!body.contains("href=\"#fnref"))
        let alpha = try #require(body.range(of: "Alpha"))
        let beta = try #require(body.range(of: "Beta"))
        #expect(alpha.lowerBound < beta.lowerBound)
    }

    @Test("外部includeを読み込まず囲みで示す")
    func includes() throws {
        let body = try AsciiDocConverter.convert("include::other.adoc[]").body
        #expect(body.contains("other.adoc"))
        #expect(body.contains("callout"))
    }

    @Test("生HTMLのスクリプトとイベント属性を除き本文を残す")
    func raw() throws {
        let body = try AsciiDocConverter.convert("++++\n<b onclick='bad()'>Safe</b><script>bad()</script>\n++++").body
        #expect(body.contains("<b>Safe</b>"))
        #expect(!body.contains("bad()"))
    }

    @Test("数式の行内・別行と未対応のAsciiMathを区別する")
    func math() throws {
        let body = try AsciiDocConverter.convert(
            ":stem: latexmath\n\nMath stem:[x] asciimath:[a/b].\n\n[latexmath]\n++++\ny^2\n++++"
        ).body
        for text in ["math-inline", "math-display", "math-error", "a/b"] { #expect(body.contains(text)) }
    }

    @Test("AsciiMathの別行は原文だけを残す")
    func asciiMathBlock() throws {
        let html = try AsciiDocConverter.convert("[asciimath]\n++++\na/b\n++++").body
        #expect(html.contains("<pre class=\"math-error\">a/b</pre>"))
    }

    @Test("表の見出し・脚・列の結合と揃えを残す")
    func table() throws {
        let body = try AsciiDocConverter.convert(
            ".Grid\n[cols=\"1,>1\",options=\"header,footer\"]\n|===\n|A |B\n2+|Both\n|F |G\n|==="
        ).body
        for text in ["<thead>", "<tfoot>", "colspan=\"2\"", "halign-right", "Grid"] { #expect(body.contains(text)) }
    }

    @Test("画像の相対位置と幅・キャプションを残す")
    func images() throws {
        let body = try AsciiDocConverter.convert(".Picture\nimage::media/image.png[Image,120]").body
        for text in ["<figure", "<figcaption>", "Picture", "src=\"media/image.png\"", "width=\"120\""] {
            #expect(body.contains(text))
        }
    }

    @Test("引用と詩の改行・出典を保つ")
    func quotes() throws {
        let html = try AsciiDocConverter.convert(
            "[quote,Editor,Book]\n____\nQuote\n____\n\n[verse,Team]\n____\nOne\nTwo\n____"
        ).body
        for text in ["<blockquote>", "Editor", "<cite>Book", "One\nTwo", "Team"] { #expect(html.contains(text)) }
    }

    @Test("サイドバー・例・オープンブロック・整形済み原文の内容を保つ")
    func blocks() throws {
        let html = try AsciiDocConverter.convert(
            ".Side\n****\nSidebar\n****\n\n.Example\n====\nExample text\n====\n\n--\nOpen\n--\n\n....\n<x>\n...."
        ).body
        for text in ["Side", "Example text", "Open", "&lt;x&gt;"] { #expect(html.contains(text)) }
    }

    @Test("用語リスト・横並びの用語・入れ子のチェック項目と継続段落を保つ")
    func lists() throws {
        let html = try AsciiDocConverter.convert(
            "Term:: Definition\n\n[horizontal]\nWord:: Meaning\n\n* [x] Done\n** Child\n+\nContinuation"
        ).body
        for text in [
            "<dl>", "Definition", "hdlist", "Meaning", "task-list-item", "disabled checked", "Child", "Continuation",
        ] {
            #expect(html.contains(text))
        }
    }

    @Test("キーボード・ボタン・メニューと改ページ・水平線を保つ")
    func macros() throws {
        let html = try AsciiDocConverter.convert(
            ":experimental:\n\nkbd:[Ctrl+P] btn:[Print] menu:File[Print]\n\n<<<\n\n'''"
        ).body
        for text in ["<kbd>Ctrl", "button", "menuitem", "page-break", "<hr>"] { #expect(html.contains(text)) }
    }

    @Test("インライン画像と外部リンクを保持する")
    func inlineImage() throws {
        let html = try AsciiDocConverter.convert("Image image:icons/a.png[A] and https://example.org[Example].").body
        #expect(html.contains("src=\"icons/a.png\""))
        #expect(html.contains("href=\"https://example.org\""))
    }
}

extension AsciiDocTests {
    @Test("lang が ja の文書の目次の題は「目次」にし、原稿の toc-title と英語の文書の題は変えない")
    func japaneseContentsTitle() throws {
        let japanese = try AsciiDocConverter.convert("= 題\n:lang: ja\n:toc:\n\n== 節\n\n本文。").body
        #expect(japanese.contains(">目次</"))
        #expect(!japanese.contains("Table of Contents"))
        let written = try AsciiDocConverter.convert("= 題\n:lang: ja\n:toc:\n:toc-title: 項目\n\n== 節\n\n本文。").body
        #expect(written.contains(">項目</"))
        let english = try AsciiDocConverter.convert("= Title\n:toc:\n\n== Part\n\nText.").body
        #expect(english.contains("Table of Contents"))
    }
}
