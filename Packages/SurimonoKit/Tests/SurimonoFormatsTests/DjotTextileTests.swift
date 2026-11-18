import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct DjotTextileTests {
    @Test("最初の大見出しを表題にし、自動IDと指定IDを見出しに付ける", arguments: [DocumentFormat.djot, .textile])
    func headings(format: DocumentFormat) throws {
        let doc = try convert(format, "# My Title!\n\n{#fixed}\n## Other", "h1. My Title!\n\nh2(#fixed). Other")
        #expect(doc.title == "My Title!")
        #expect(doc.body.contains("<h1 id=\"my-title\">"))
        #expect(doc.body.contains("<h2 id=\"fixed\">"))
    }

    @Test("並行して開いた文書の表題を混同しない", arguments: [DocumentFormat.djot, .textile])
    func concurrent(format: DocumentFormat) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 1...12 {
                group.addTask { try convert(format, "# Paper \(i)", "h1. Paper \(i)").title == "Paper \(i)" }
            }
            for try await matches in group { #expect(matches) }
        }
    }

    @Test("図のコードを描画用の要素にする", arguments: ["mermaid", "dot", "graphviz", "plantuml", "puml"])
    func diagrams(language: String) throws {
        for format in [DocumentFormat.djot, .textile] {
            let doc = try convert(format, "```\(language)\na -> b\n```", "bc(\(language)). a -> b")
            #expect(
                doc.body.contains(
                    language == "mermaid"
                        ? "mermaid-block"
                        : (["dot", "graphviz"].contains(language) ? "graphviz-block" : "plantuml-block")))
        }
    }

    @Test("脚注を初出順に集め再参照と戻りリンクを処理する", arguments: [DocumentFormat.djot, .textile])
    func footnotes(format: DocumentFormat) throws {
        let doc = try convert(
            format, "A[^b] B[^a] C[^b]\n\n[^a]: Alpha\n[^b]: Beta",
            "A[2] B[1] C[2]\n\nfn1. Alpha\n\nfn2. Beta")
        #expect(doc.body.contains("id=\"fnref-1-2\""))
        let notes = try #require(doc.body.components(separatedBy: "<section class=\"footnotes\"><ol>").last)
        #expect(try #require(notes.range(of: "Beta")).lowerBound < #require(notes.range(of: "Alpha")).lowerBound)
        #expect(!notes.contains("href=\"#fnref"))
    }

    @Test("生HTMLのスクリプトとイベント属性を除く", arguments: [DocumentFormat.djot, .textile])
    func raw(format: DocumentFormat) throws {
        let input = "<b onclick='bad()'>OK</b><script>bad()</script>"
        let doc = try convert(format, "```=html\n\(input)\n```", input)
        #expect(doc.body.contains("<b>OK</b>"))
        #expect(!doc.body.contains("bad()"))
    }

    @Test("数式を組版して読めない式を表示する")
    func math() throws {
        let body = try DjotConverter.convert(#"$`x^2` と $$`\unknowncommand`"#).body
        #expect(body.contains("<svg"))
        #expect(body.contains("math-error"))
    }

    @Test("既知の囲みと独自の囲みを区別する")
    func callouts() throws {
        let body = try DjotConverter.convert("::: warning\n注意\n:::\n\n::: custom\nCustom\n:::").body
        #expect(body.contains("callout-warning"))
        #expect(body.contains("<div class=\"custom\">"))
    }

    @Test("表の見出しと相対画像を保つ", arguments: [DocumentFormat.djot, .textile])
    func tables(format: DocumentFormat) throws {
        let doc = try convert(
            format, "| Item |\n|:---:|\n| Pen |\n\n![紙](media/paper.png)",
            "|_. Item |\n| Pen |\n\n!media/paper.png(紙)!")
        #expect(doc.body.contains("<th"))
        #expect(doc.body.contains("src=\"media/paper.png\""))
    }

    @Test(
        "配布されたJavaScriptを改変せず同梱する",
        arguments: [
            ("djot-0.3.2", "a0d679a7011693daa3807421ba15a3a963c61f05682378c926b6fccb74821bdd"),
            ("textile-2.1.1", "a4501f6f0932e507fede8c18a5b74475a16185b29ee692d262e8354d18bd4eb4"),
        ])
    func bundle(name: String, expected: String) throws {
        let bytes = try Data(contentsOf: ScriptConverterHost.scriptURL(name))
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected)
    }

    @Test("5 MBを超える原文を通知とともに表示する", arguments: [DocumentFormat.djot, .textile])
    func large(format: DocumentFormat) throws {
        let source = String(repeating: "紙", count: 1_666_667) + "<end>"
        let doc = try convert(format, source, source)
        for text in ["5 MB", "surimono-plain", "&lt;end&gt;"] { #expect(doc.body.contains(text)) }
    }

    @Test("タスク項目を印刷用のチェック欄にする", arguments: [DocumentFormat.djot, .textile])
    func tasks(format: DocumentFormat) throws {
        let body = try convert(format, "- [x] Ready", "* [x] Ready").body
        for text in ["task-list-item", "checked", "disabled", "Ready"] { #expect(body.contains(text)) }
    }

    @Test("自動参照を重複しない見出しIDに合わせる")
    func internalLinks() throws {
        let body = try DjotConverter.convert("[Go][My Title!]\n\n# My Title!\n\n# My Title!").body
        for text in ["href=\"#my-title\"", "id=\"my-title\"", "id=\"my-title-1\""] { #expect(body.contains(text)) }
    }

    @Test("後から指定されたIDを自動見出しが奪わない", arguments: [DocumentFormat.djot, .textile])
    func reservedIDs(format: DocumentFormat) throws {
        let body = try convert(format, "# Paper\n\n{#paper}\n## Manual", "h1. Paper\n\nh2(#paper). Manual").body
        #expect(body.contains("<h1 id=\"paper-1\">Paper"))
        #expect(body.contains("<h2 id=\"paper\">Manual"))
    }

    @Test("絵文字の別名は本文だけで変換する")
    func symbols() throws {
        let body = try DjotConverter.convert(":tada: :unknown_symbol: `:tada:`").body
        for text in ["🎉", ":unknown_symbol:", "<code>:tada:</code>"] { #expect(body.contains(text)) }
    }

    @Test("Textileの段落では単一改行と属性を保つ")
    func textileAttributes() throws {
        let body = try TextileConverter.convert("p(note#custom){color:navy}[ja]. Paper\nFold").body
        for text in ["class=\"note\"", "id=\"custom\"", "style=\"color:navy\"", "lang=\"ja\"", "<br>"] {
            #expect(body.contains(text))
        }
    }

    @Test("Djotの表は表題と各列の揃えを保つ")
    func djotTable() throws {
        let body = try DjotConverter.convert("| Left | Right |\n|:---|---:|\n| A | B |\n\n^ 用紙").body
        for text in ["<caption>用紙", "text-align: left", "text-align: right"] { #expect(body.contains(text)) }
    }

    @Test("Textileの表はセル結合と右揃えを保つ")
    func textileTable() throws {
        let body = try TextileConverter.convert("|_. Paper|_. Sheets|\n| A4|>. 2|\n|\\2. Total|").body
        for text in ["<th>Paper", "colspan=\"2\"", "text-align:right"] { #expect(body.contains(text)) }
    }

    @Test("定義リストと語の説明を保つ", arguments: [DocumentFormat.djot, .textile])
    func definitions(format: DocumentFormat) throws {
        let body = try convert(format, ": Sheet\n\n  Paper", "- Sheet := Paper").body
        for text in ["<dl>", "<dt>Sheet", "<dd>", "Paper"] { #expect(body.contains(text)) }
    }

    @Test("DjotはHTMLの生の断片だけを取り込む")
    func rawFormats() throws {
        let body = try DjotConverter.convert("`<em>Paper</em>`{=html}\n\n```=latex\nhidden\n```").body
        #expect(body.contains("<em>Paper</em>"))
        #expect(!body.contains("hidden"))
    }

    @Test("Textileの別名リンクと略語を読む")
    func aliases() throws {
        let body = try TextileConverter.convert(
            "[guide]https://example.org/print\n\n\"用紙\":guide / PDF(Portable Document Format)"
        ).body
        #expect(body.contains("href=\"https://example.org/print\""))
        #expect(body.contains("title=\"Portable Document Format\""))
    }

    @Test("Textileの整形抑止をインラインとブロックで保つ")
    func noTextile() throws {
        let body = try TextileConverter.convert("notextile. *Paper*\n\n==*Fold*==").body
        #expect(body.contains("*Paper*"))
        #expect(body.contains("*Fold*"))
    }

    private func convert(_ format: DocumentFormat, _ djot: String, _ textile: String) throws -> HTMLFragment {
        try format == .djot ? DjotConverter.convert(djot) : TextileConverter.convert(textile)
    }
}
