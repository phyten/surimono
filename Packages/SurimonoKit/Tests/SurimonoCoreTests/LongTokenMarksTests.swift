import Testing

@testable import SurimonoCore

@Suite("長いパスや URL の折り返し")
struct LongTokenMarksTests {
    private let path = "/var/folders/fz/bqjk04/T/local-push-501.lock"

    @Test("和文の中の長いパスに印を付ける")
    func marksPath() {
        #expect(
            LongTokenMarks.marked("<p>過去の位置：\(path)。</p>")
                == "<p>過去の位置：<span class=\"long-token\">\(path)</span>。</p>")
    }

    @Test("短い語と区切りのない長い英単語はそのままにする")
    func leavesOrdinaryWords() {
        let html = "<p>lock と a/b と antidisestablishmentarianism</p>"
        #expect(LongTokenMarks.marked(html) == html)
    }

    @Test("タグの属性の中の URL は変えない")
    func leavesAttributes() {
        let html = "<a href=\"https://example.com/a/very/long/path/to/a/file\">資料</a>"
        #expect(LongTokenMarks.marked(html) == html)
    }

    @Test("属性の中の > の後の長いパスは変えない")
    func leavesQuotedGreaterThan() {
        let html = "<a title=\"x > \(path)\" href=\"ok\">本文</a>"
        #expect(LongTokenMarks.marked(html) == html)
    }

    @Test("コメントの中の開きタグで印を止めない")
    func readsPastComments() {
        #expect(LongTokenMarks.marked("<!-- > <pre> --><p>\(path)</p>").contains("long-token"))
    }

    @Test("スクリプトの中の < の後も閉じタグで元に戻る")
    func resumesAfterScript() {
        let marked = LongTokenMarks.marked("<script>if (a < b) x = 1;</script><p>\(path)</p>")
        #expect(marked.hasPrefix("<script>if (a < b) x = 1;</script>"))
        #expect(marked.contains("long-token"))
    }

    @Test("入れ子のコードブロック要素の後で元に戻る")
    func tracksNesting() {
        #expect(
            LongTokenMarks.marked("<svg><svg>\(path)</svg>\(path)</svg><p>\(path)</p>").components(
                separatedBy: "long-token"
            ).count == 2)
    }

    @Test("リンクの文字とインラインのコードには印を付ける")
    func marksInlineElements() {
        #expect(LongTokenMarks.marked("<code>\(path)</code>").contains("long-token"))
        #expect(LongTokenMarks.marked("<a href=\"x\">\(path)</a>").contains("long-token"))
    }

    @Test("コードブロック・SVG・スタイルの中は変えない")
    func leavesRawElements() {
        for name in ["pre", "svg", "style", "script"] {
            let html = "<\(name) class=\"x\"><b>\(path)</b></\(name)>"
            #expect(LongTokenMarks.marked(html) == html)
        }
    }

    @Test("コードブロックの後の文字には印を付ける")
    func resumesAfterRawElement() {
        #expect(LongTokenMarks.marked("<pre>a</pre><p>\(path)</p>").contains("long-token"))
    }

    @Test("実体参照を割らない")
    func keepsEntities() {
        let html = "<p>https://example.com/?a=1&amp;b=2&amp;c=3</p>"
        #expect(LongTokenMarks.marked(html).contains("&amp;b=2&amp;c=3</span>"))
    }

    @Test("組み上がった文書に印が入る")
    func builderMarks() {
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<p>\(path)</p>"), format: .markdown,
            theme: PrintTheme(id: "t", name: "T", css: ""))
        #expect(html.contains("long-token\">\(path)"))
    }
}
