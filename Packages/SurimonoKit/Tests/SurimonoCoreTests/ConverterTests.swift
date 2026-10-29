import SurimonoCore
import Testing

struct ConverterTests {
    @Test("プレーンテキストは特殊文字をエスケープしタブを保持する")
    func plainText() {
        #expect(
            PlainTextConverter.convert("<x> & \"a\"\t'").body
                == "<pre class=\"surimono-plain\">&lt;x&gt; &amp; &quot;a&quot;\t&#39;</pre>")
    }

    @Test("CSVは引用符とフィールド内改行と空欄を読む")
    func csv() {
        let result = CSVConverter.convert("name,note,empty\r\n\"a,b\",\"line1\r\n\"\"line2\"\"\",\r\n")
        #expect(
            result.body
                == "<table class=\"surimono-csv\"><thead><tr><th>name</th><th>note</th><th>empty</th></tr></thead><tbody><tr><td>a,b</td><td>line1\n&quot;line2&quot;</td><td></td></tr></tbody></table>"
        )
    }

    @Test("TSVはタブで区切り特殊文字をエスケープする")
    func tsv() {
        let body = CSVConverter.convert("A\tB\n<x>\t&", delimiter: "\t").body
        #expect(body.contains("<th>A</th><th>B</th>"))
        #expect(body.contains("<td>&lt;x&gt;</td><td>&amp;</td>"))
        #expect(CSVConverter.convert("").body.contains("<tbody></tbody>"))
    }

    @Test("MarkdownのGFM表と取り消し線とタスクと自動リンクを出す")
    func gfm() {
        let body = MarkdownConverter.convert(
            "| A | B |\n| :- | -: |\n| x | y |\n\n~~gone~~\n\n- [x] done\n- [ ] next\n\nhttps://example.com"
        ).body
        #expect(body.contains("<table>"))
        #expect(body.contains("<thead>"))
        #expect(body.contains("<del>gone</del>"))
        #expect(body.contains("checked"))
        #expect(body.contains("type=\"checkbox\""))
        #expect(body.contains("href=\"https://example.com\""))
    }

    @Test("Markdownのfront matterを除き表題を取り出す")
    func frontMatter() {
        let result = MarkdownConverter.convert("---\ntitle: \"本 & 紙\"\nauthor: Example\n---\n# 見出し\n本文")
        #expect(result.title == "本 & 紙")
        #expect(!result.body.contains("author"))
        #expect(result.body.contains("<h1>見出し</h1>"))
    }

    @Test("閉じていないfront matterは削除しない")
    func unclosedFrontMatter() {
        #expect(MarkdownConverter.convert("---\ntitle: 残す").body.contains("title: 残す"))
    }

    @Test("Markdownの最初のH1を表題にし装飾を保持する")
    func heading() {
        let result = MarkdownConverter.convert("## 先\n# **本** & 紙\n# 次")
        #expect(result.title == "本 & 紙")
        #expect(result.body.contains("<h1><strong>本</strong> &amp; 紙</h1>"))
    }

    @Test("Markdownの本文とコードをエスケープし明示的な生HTMLは保持する")
    func markdownEscaping() {
        let body = MarkdownConverter.convert("a & b\n\n`<x>`\n\n```html\n<script>&\n```\n\n<div>raw</div>").body
        #expect(body.contains("a &amp; b"))
        #expect(body.contains("<code>&lt;x&gt;</code>"))
        #expect(body.contains("&lt;script&gt;&amp;"))
        #expect(body.contains("<div>raw</div>"))
    }

    @Test("Markdownの画像に代替文と安全な属性を付ける")
    func markdownImage() {
        let body = MarkdownConverter.convert("![a & b](image.png \"caption\")").body
        #expect(body.contains("alt=\"a &amp; b\""))
        #expect(body.contains("title=\"caption\""))
    }

    @Test("自動リンクはURLとwwwとメールを認識し末尾の句読点を除く")
    func autolinks() {
        let body = MarkdownConverter.convert("(https://example.com/a(b)). www.example.com, hello@example.com!").body
        #expect(body.contains("href=\"https://example.com/a(b)\">https://example.com/a(b)</a>)."))
        #expect(body.contains("href=\"http://www.example.com\">www.example.com</a>,"))
        #expect(body.contains("href=\"mailto:hello@example.com\">hello@example.com</a>!"))
    }

    @Test("コードと既存リンク内では自動リンクを追加しない")
    func noNestedAutolinks() {
        let body = MarkdownConverter.convert("`https://example.com` [https://example.com](other.html)").body
        #expect(body.contains("<code>https://example.com</code>"))
        #expect(body.contains("<a href=\"other.html\">https://example.com</a>"))
        #expect(body.components(separatedBy: "<a ").count == 2)
    }

    @Test("URL風のメールアドレスもmailtoとして出す", arguments: ["https@example.com", "www.name@example.com"])
    func emailPrefixes(address: String) {
        #expect(MarkdownConverter.convert(address).body.contains("href=\"mailto:\(address)\""))
    }

    @Test("生HTMLのリンクをそのまま保持する")
    func rawAnchor() {
        let source = "before <a href=\"other.html\">https://example.com</a> after"
        #expect(MarkdownConverter.convert(source).body == "<p>\(source)</p>\n")
    }

    @Test("文書形式に応じてテーマとHTMLプリセットを選べる")
    func formatCapabilities() {
        #expect(DocumentFormat(fileExtension: "tsv") == .csv)
        #expect(DocumentFormat.allCases.filter(\.usesPrintTheme) == [.markdown, .org, .plainText, .csv])
        #expect(DocumentFormat.allCases.filter(\.usesHTMLPreset) == [.html])
        #expect(DocumentFormat.allCases.filter { !$0.isWebRendered } == [.pdf, .image, .zipArchive])
    }

    @Test("Markdownの表のヘッダーと本文で生HTMLアンカーを入れ子にしない")
    func rawTableAnchors() {
        let body = MarkdownConverter.convert(
            "| <a href=\"other.html\">https://example.com</a> |\n| --- |\n| <a href=\"other.html\">https://example.com</a> |"
        ).body
        #expect(
            body
                == "<table><thead><tr><th><a href=\"other.html\">https://example.com</a></th></tr></thead><tbody><tr><td><a href=\"other.html\">https://example.com</a></td></tr></tbody></table>\n"
        )
    }

    @Test("MarkdownのURL末尾の括弧20万文字を時間内にリンク外へ分離する", .timeLimit(.minutes(1)))
    func trailingParenthesesStress() {
        let body = MarkdownConverter.convert("https://example.com/" + String(repeating: ")", count: 200_000)).body
        #expect(
            body == "<p><a href=\"https://example.com/\">https://example.com/</a>"
                + String(repeating: ")", count: 200_000) + "</p>\n")
    }
}
