import Foundation
import Testing

@testable import SurimonoCore

struct MediaWikiTests {
    @Test("原文の各記法を紙用の要素にする", arguments: cases)
    func syntax(_ pair: [String]) {
        #expect(MediaWikiConverter.convert(pair[0]).body.contains(pair[1]))
    }

    static let cases = [
        ["== Paper == <!-- end -->", "<h2 id=\"paper\">Paper</h2>"],
        ["a\nb", "<p>a b</p>"], ["----", "<hr>"], [" abc", "<pre>abc</pre>"],
        ["<nowiki>[[X]]</nowiki>", "[[X]]"], ["<poem>a\nb</poem>", "a<br>b"],
        ["<chem>H2O</chem>", "<code>H2O</code>"],
        ["* a\n*# b", "<ol><li>b"], ["# a\n#* b", "<ul><li>b"], [";term:def", "<dt>term</dt><dd>def</dd>"],
        [": talk", "<blockquote>"], ["{|\n|+ Title\n|-\n! A !! B\n|}", "<caption>Title</caption>"],
        ["{|\n| colspan=2 | yes", "colspan=\"2\""], ["<ref name=a/> x <ref name=a>note</ref>", "id=\"fn-1\">note"],
        ["l'''arbre''", "l&#39;<em>arbre</em>"], ["''open", "<em>open</em>"],
        ["[[Help:Contents|]]", ">Contents</span>"], ["[[bus]]es", "buses</span>"],
        ["== Page ==\n[[#Page]]", "href=\"#page\""], ["[[:Category:X]]", ">Category:X</span>"],
        ["[[Category:X]]", "wiki-categories"], ["[https://example.org]", ">[1]</a>"],
        ["{{lang|en|ink}}", "<span lang=\"en\">ink</span>"], ["A {{unknown|1}}", "wiki-template"],
        ["{{Box\n|key={{small|ink}}\n}}", "<small>ink</small>"], ["{{unclosed", "{{unclosed"],
        ["<script>x</script>", "&lt;script&gt;"], ["x<!--a\nb-->y", "<p>xy</p>"],
        ["__TOC__\n== Contents ==", "<nav class=\"toc\">"], ["#REDIRECT [[Other]]", "Redirect to Other"],
        ["[[File:absent.png|thumb|caption]]", "absent.png"], ["<timeline>raw</timeline>", "wiki-note"],
        ["'''bold'''", "<strong>bold</strong>"],
        ["'''''both'''''", "<em><strong>both</strong></em>"],
        ["'''''a'' b'''", "<strong><em>a</em> b</strong>"],
        ["'''a ''b''' c''", "<strong>a <em>b</em></strong><em> c</em>"],
        ["======= title =======", "======= title ======="],
        [";first:def\n;second:def", "</dd><dt>second</dt>"],
        [";term\n:definition", "<dt>term</dt><dd>definition</dd>"],
        ["<pre>''unparsed''</pre>", "&#39;&#39;unparsed&#39;&#39;"],
        ["<kbd id=a>k</kbd>", "<kbd id=\"a\">k</kbd>"],
        ["x<br />y", "x<br>y"],
        ["<abbr title='abbreviation'>A</abbr>", "title=\"abbreviation\""],
        ["<source lang=swift>let n = 1</source>", "class=\"language-swift hl\""],
        ["<syntaxhighlight lang=mermaid>a</syntaxhighlight>", "class=\"mermaid-block\""],
        ["<source lang=dot>a</source>", "class=\"graphviz-block\""],
        ["<source lang=graphviz>a</source>", "class=\"graphviz-block\""],
        ["<source lang=plantuml>a</source>", "class=\"plantuml-block\""],
        ["<math>x</math>", "class=\"math math-inline\""],
        ["<math display=\"block\">x</math>", "class=\"math math-display\""],
        [": <math>x</math>", "class=\"math math-display\""],
        ["<math></math>", "class=\"math-error\""],
        ["[[Page#Section|read]]", ">read</span>"],
        ["[[Page]]", ">Page</span>"],
        ["[[#Missing]]", ">#Missing</span>"],
        ["[[Media:x.wav|sound]]", ">sound</span>"],
        ["[http://example.org ''site'']", "<em>site</em></a>"],
        ["[https://example.org] [https://example.org]", ">[2]</a>"],
        ["mailto:a@example.org.", "href=\"mailto:a@example.org\""],
        ["https://example.org/a(b)).", "href=\"https://example.org/a(b)\""],
        ["A&nbsp;&amp;B", "A&nbsp;&amp;B"],
        ["~~~~ ISBN 978123 RFC 1234", "~~~~ ISBN 978123 RFC 1234"],
        ["{{!}}{{=}}{{nbsp}}{{spaces}}", "|=&nbsp;&nbsp;"],
        ["a{{clear}}b{{-}}c", "<p>abc</p>"],
        ["{{small|type}}", "<small>type</small>"],
        ["{{math|x}}", "<code>x</code>"],
        ["{{nowrap|a b}}", "class=\"wiki-nowrap\""],
        ["{{quote|ink|author}}", "<cite>author</cite>"],
        ["{{Main|Paper}}", "Main article: Paper"],
        ["{{See_also|Paper}}", "See also: Paper"],
        ["{{仮リンク|紙|en|Paper}}", "紙"],
        ["A {{#if:yes|true|false}}", ">#if</small>"],
        ["A {{{1}}}", ">1</small>"],
        ["A {{PAGENAME}}", ">PAGENAME</small>"],
        [
            "{{cite web|last=Smith|first=A|title=Notes|url=https://example.org"
                + "|publisher=Press|date=2026|access-date=May}}",
            "A Smith. Notes. <a href=\"https://example.org\">https://example.org</a>. Press. 2026. Accessed May",
        ],
        ["<gallery>File:absent.png|''fold''</gallery>", "<em>fold</em>"],
        ["<unknownextension>data</unknownextension>", "&lt;unknownextension&gt;"],
        ["<references />\n== Next ==\nx<ref>body</ref>", "</section><h2"],
        ["<ref>n</ref>\n{{reflist}}", "<li id=\"fn-1\">n</li>"],
        ["[[ja:Other]]visible", "<p>visible</p>"],
        ["__NOEDITSECTION__x__HIDDENCAT__", "<p>x</p>"],
        ["__FORCETOC__\n== Heading ==", "<nav class=\"toc\">"],
    ]

    @Test("最初の一級見出しだけを文書の題にする")
    func title() {
        #expect(MediaWikiConverter.convert("== Small ==\n= Title =\n= More =").title == "Title")
        #expect(MediaWikiConverter.convert("== Small ==").title == nil)
    }

    @Test("入れ子の表の後も外のセル内でリストを組む")
    func nestedTable() throws {
        let body = MediaWikiConverter.convert("{|\n| outer\n{|\n| inner\n|}\n* after\n|}").body
        try MarkupHTML.withBody(body) { root in
            let cell = try #require(root.child("table")?.child("tr")?.child("td"))
            #expect(cell.child("table")?.text == "inner\n")
            #expect(cell.child("ul")?.text == "after")
        }
    }

    @Test("同じ脚注を再利用し、指定位置にグループ単位で一覧を置く")
    func referencePlacement() {
        let html = MediaWikiConverter.convert(
            """
            <references group="n" />
            == Middle ==
            A<ref group=n name=x/> B<ref group=n name=x>first</ref> C<ref>second</ref>
            """
        ).body
        let parts = html.components(separatedBy: "<h2")
        #expect(parts[0].contains("first"))
        #expect(parts[1].contains("second"))
        #expect(parts[1].components(separatedBy: ">n 1</a>").count == 3)
        #expect(!html.contains("backref"))
    }

    @Test("隣の画像名の空白と下線を同一視し、幅と代替文字を付ける")
    func adjacentImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("fold paper.png"))
        let html = MediaWikiConverter.convert("[[画像:fold_paper.png|thumb|right|200px|alt=fold|印]]", directory: folder)
            .body
        #expect(html.contains("fold%20paper"))
        #expect(html.contains("width=\"200\""))
        #expect(html.contains("alt=\"fold\""))
        #expect(html.contains("<figcaption>印</figcaption>"))
    }

    @Test("画像の親フォルダーや権限外の画像を参照しない")
    func imageAccess() {
        let dir = URL(fileURLWithPath: "/sample")
        let html = MediaWikiConverter.convert("[[Image:../escape.png]]\n[[File:private.png]]", directory: dir) { _ in
            false
        }.body
        #expect(!html.contains("<img"))
        #expect(html.contains("private.png"))
    }

    @Test("全ての見出しレベルに一意なアンカーを付ける", arguments: 1...6)
    func headingLevels(_ level: Int) {
        let mark = String(repeating: "=", count: level)
        let line = "\(mark) Note \(mark)"
        let html = MediaWikiConverter.convert(line + "\n" + line).body
        #expect(html.contains("<h\(level) id=\"note\">"))
        #expect(html.contains("<h\(level) id=\"note-1\">"))
    }

    @Test(
        "処理できない拡張タグの名前を枠に出す",
        arguments: ["imagemap", "timeline", "score", "graph", "mapframe", "categorytree", "custom"])
    func extensionNote(_ name: String) {
        let html = MediaWikiConverter.convert("<\(name)>example</\(name)>").body
        #expect(html.contains("class=\"wiki-note\""))
        #expect(html.contains("&lt;\(name)&gt;"))
    }

    @Test("原文のHTML属性を限定し表のセルには横位置だけを残す")
    func filters() {
        let html = MediaWikiConverter.convert(
            """
            <span class="a" onclick="bad" data-extra="x">ok</span>
            <iframe>text</iframe>
            {|
            | rowspan=2 style="color:red;text-align:right" | cell
            |}
            """
        ).body
        #expect(html.contains("<span class=\"a\">ok</span>"))
        #expect(html.contains("&lt;iframe&gt;text&lt;/iframe&gt;"))
        #expect(html.contains("text-align:right"))
        for key in ["onclick=", "data-extra=", "color:red"] { #expect(!html.contains(key)) }
    }

    @Test("テンプレートに表示する名前付き引数は四十行まで")
    func templateLimit() {
        let html = MediaWikiConverter.convert("{{Box|" + (1...50).map { "k=val-\($0)" }.joined(separator: "|") + "}}")
            .body
        #expect(html.contains("val-40"))
        #expect(!html.contains("val-41"))
        #expect(html.contains(">…</td>"))
    }

    @Test("目次抑止と名前空間は本文に記号を残さない")
    func suppressed() {
        let html = MediaWikiConverter.convert("__TOC__\n__NOTOC__\n== Ink ==\n[[ja:Other]] [[Category:Paper|Sort]]")
            .body
        for hidden in ["__TOC__", "__NOTOC__", "<nav", "Other", "Sort"] { #expect(!html.contains(hidden)) }
        #expect(html.contains("Categories: Paper"))
    }

    @Test("角括弧のリンクを含むMarkdownをMarkdownとして開く")
    func obsidian() {
        let source = "# Title\n\nText [[Other]].\n\n## Section\n\n- one\n- two\n- three\n"
        #expect(ClipboardFormatDetector.detect(source).action == .open(.markdown))
    }

    @Test("同じ種類の手がかりを二度数えない")
    func repeatedSignal() {
        for text in ["[[A]] and [[B]]", "[[Paper]] and `{{example}}`", "[[Paper]] <!-- {{Hidden}} -->"] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.mediawiki))
        }
    }

    @Test("強制目次は最初の見出しの前に一度だけ置く")
    func forcedTOC() {
        let html = MediaWikiConverter.convert("Opening\n== First ==\n__FORCETOC__\n__FORCETOC__").body
        #expect(html.components(separatedBy: "<nav").count == 2)
        #expect(html.components(separatedBy: "<h2")[0].contains("<nav"))
    }

    @Test("生のブロック要素は段落で包まない")
    func rawBlocks() {
        let body = MediaWikiConverter.convert("<blockquote>text</blockquote>\n<ul><li>item</li></ul>").body
        #expect(!body.contains("<p>"))
    }

    @Test("容量上限を超えたら原文を刷る")
    func largeSource() {
        let html = MediaWikiConverter.convert("== literal ==\n" + String(repeating: "a", count: 5_000_000)).body
        #expect(html.contains("<pre class=\"surimono-plain\">== literal =="))
    }

    @Test("見本の読取時間と表題を確かめる")
    func sample() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Samples/sample.mediawiki"), encoding: .utf8)
        let duration = ContinuousClock().measure {
            #expect(MediaWikiConverter.convert(source).title == "紙の試験室 / Paper workshop")
        }
        print("MediaWiki sample", source.utf8.count, duration)
    }

    @Test("三つの拡張子で認識する", arguments: ["wiki", "mediawiki", "wikitext"])
    func suffix(_ suffix: String) { #expect(DocumentFormat(fileExtension: suffix) == .mediawiki) }

    @Test("独立した記号を二つ必要とする")
    func clipboard() {
        #expect(ClipboardFormatDetector.detect("== Notes ==\n[[Paper]]").action == .open(.mediawiki))
        for source in ["# Notes\n[[Paper]]", "* Notes\n[[Paper]]", "= Notes\n== Paper", "plain text"] {
            #expect(ClipboardFormatDetector.detect(source).action != .open(.mediawiki))
        }
    }

    @Test("未閉鎖記号・深い入れ子・五千行の表を時間内に読む", .timeLimit(.minutes(1)))
    func pathological() {
        let source =
            String(repeating: "{{", count: 50_000) + "\n"
            + String(repeating: "{{a|", count: 10_000) + "x" + String(repeating: "}}", count: 10_000)
            + "\n" + String(repeating: "[[<ref>''", count: 5000)
            + "\n{|\n" + String(repeating: "|-\n| ink || paper\n", count: 5000) + "|}"
        let duration = ContinuousClock().measure {
            let body = MediaWikiConverter.convert(source).body
            #expect(body.components(separatedBy: "</tr>").count == 5001)
        }
        print("MediaWiki pathological", source.utf8.count, duration)
        #expect(duration < .seconds(15))
    }
}
