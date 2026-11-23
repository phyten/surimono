import SurimonoFormats
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FragmentChangesTests {
    @Test("色付きの8万 UTF-16 単位の1行にも時間内に変更印を付ける")
    func longColoredLine() {
        let token = #"<span class="hl-keyword">let</span> a = <span class="hl-number">1</span>;"#
        let line = String(repeating: token, count: 8_000)
        let start = #"<pre class="surimono-plain">"#
        let html = start + line + "</pre>"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let change = marks(start + "old</pre>", html)
            #expect(change == [.init(blockID: "lines-0-0")])
            let marked = FragmentChanges.identifyingBlocks(in: html, for: change)
            #expect(marked == start + #"<span data-surimono-block="lines-0-0">"# + line + "</span></pre>")
        }
        #expect(elapsed < .seconds(8))
    }

    private func marks(_ old: String, _ new: String) -> [MarkdownMarkRequest] {
        FragmentChanges.marks(from: old, to: new)
    }

    @Test("同じ文書と通常の空白だけの変更には印を付けない")
    func unchanged() {
        #expect(marks("<p>A</p>", "<p>A</p>").isEmpty)
        #expect(marks("<p>A  B</p>", "\n<p>A\n B</p>").isEmpty)
    }

    @Test("書き換えた段落と差し込んだ段落だけに印を付ける")
    func paragraph() {
        let old = "<p>A</p><p>B</p><p>C</p>"
        #expect(marks(old, "<p>A</p><p>D</p><p>C</p>") == [.init(blockID: "fragment-1")])
        #expect(marks(old, "<p>A</p><p>D</p><p>B</p><p>C</p>") == [.init(blockID: "fragment-1")])
    }

    @Test("削除は次の段落に短い印を付け文末なら前の段落に付ける")
    func deletion() {
        #expect(marks("<p>A</p><p>B</p>", "<p>B</p>") == [.init(blockID: "fragment-0", isShort: true)])
        #expect(
            marks("<p>A</p><p>B</p>", "<p>A</p>") == [.init(blockID: "fragment-0", isShort: true, afterBlock: true)])
        #expect(marks("<p>A</p>", "").isEmpty)
    }

    @Test("並べ替えで移動した段落を検出する")
    func reorder() {
        let changes = marks("<p>A</p><p>B</p><p>C</p>", "<p>B</p><p>A</p><p>C</p>")
        #expect(changes.filter { !$0.isShort } == [.init(blockID: "fragment-0")])
    }

    @Test("セルの変更は同じ行に対応し前後の段落と不可視の要素を含まない")
    func table() {
        let body = "<style>p {color:red}</style><p>A<br>B</p><!-- > --><table><tr><td>X</td></tr></table><p>C</p>"
        let new = body.replacingOccurrences(of: ">X<", with: ">Y<")
        let changes = marks(body, new)
        #expect(changes == [.init(blockID: "fragment-1")])
        #expect(
            FragmentChanges.identifyingBlocks(in: new, for: changes)
                == new.replacingOccurrences(
                    of: "<tr>", with: "<tr data-surimono-block=\"fragment-1\">"))
    }

    @Test("三千行のテキストでは編集した行だけを囲み連続する変更は一つにまとめる")
    func plainText() {
        let lines = (0..<3000).map { "原文 \($0)" }
        let old = PlainTextConverter.convert(lines.joined(separator: "\n")).body
        var edited = lines
        edited[1500] = "<変更>"
        let new = PlainTextConverter.convert(edited.joined(separator: "\n")).body
        let only = marks(old, new)
        #expect(only == [.init(blockID: "lines-1500-1500")])
        #expect(
            FragmentChanges.identifyingBlocks(in: new, for: only)
                == new.replacingOccurrences(
                    of: "&lt;変更&gt;", with: "<span data-surimono-block=\"lines-1500-1500\">&lt;変更&gt;</span>"))
        edited[1501] = "もう一行"
        let consecutive = PlainTextConverter.convert(edited.joined(separator: "\n")).body
        #expect(marks(old, consecutive) == [.init(blockID: "lines-1500-1501")])
    }

    @Test("色付きのソースでは複数行コメントの途中の一行を変えてもその行だけに印を付ける")
    func coloredSource() {
        let lines = ["let a = 1", "/* first", "   second", "   third */", "let b = 2", ""]
        let old = PlainTextConverter.convert(lines.joined(separator: "\n"), fileName: "a.swift").body
        var edited = lines
        edited[2] = "   changed"
        let new = PlainTextConverter.convert(edited.joined(separator: "\n"), fileName: "a.swift").body
        let only = marks(old, new)
        #expect(only == [.init(blockID: "lines-2-2")])
        #expect(
            FragmentChanges.identifyingBlocks(in: new, for: only) == """
                <pre class="surimono-source"><span class="hl-keyword">let</span> a = <span class="hl-number">1</span>
                <span class="hl-comment">/* first</span>
                <span data-surimono-block="lines-2-2"><span class="hl-comment">   changed</span></span>
                <span class="hl-comment">   third */</span>
                <span class="hl-keyword">let</span> b = <span class="hl-number">2</span>
                </pre>
                """)
    }

    @Test("コメントを開いて後ろの行の色だけが変わったときは、書き換えた行だけに印を付ける")
    func recoloredSource() {
        let old = PlainTextConverter.convert("let a = 1\nlet b = 2\nlet c = 3\n", fileName: "a.swift").body
        let new = PlainTextConverter.convert("let a = 1 /*\nlet b = 2\nlet c = 3\n", fileName: "a.swift").body
        #expect(marks(old, new) == [.init(blockID: "lines-0-0")])
    }

    @Test("一万行までは変えた行だけに印を付け、一万一行からは印を付けず文書全体にも付けない", arguments: ["a.swift", "a.txt"])
    func lineLimit(fileName: String) {
        func body(_ count: Int, changing line: Int?) -> String {
            var lines = (0..<count).map { "let a\($0) = 1" }
            if let line { lines[line] = "let changed = 2" }
            return PlainTextConverter.convert(lines.joined(separator: "\n"), fileName: fileName).body
        }
        let atLimit = body(10_000, changing: 5000)
        let only = marks(body(10_000, changing: nil), atLimit)
        #expect(only == [.init(blockID: "lines-5000-5000")])
        #expect(FragmentChanges.identifyingBlocks(in: atLimit, for: only).contains("data-surimono-block=\"lines-5000-"))
        let over = body(10_001, changing: 5000)
        #expect(marks(body(10_001, changing: nil), over).isEmpty)
        #expect(marks(body(10_000, changing: nil), over).isEmpty)
        #expect(marks(body(10_001, changing: nil), atLimit).isEmpty)
        // A request that names the whole block must find nothing to name in a text over the limit.
        #expect(FragmentChanges.identifyingBlocks(in: over, for: [.init(blockID: "fragment-0")]) == over)
        #expect(FragmentChanges.identifyingBlocks(in: over, for: [.init(blockID: "lines-0-0")]) == over)
    }

    @Test("一万個目の改行で読むのをやめ、その先の数 MB の行も、もう片方の文書も行に分けない", arguments: ["a.swift", "a.txt"])
    func stopsAtTheLimit(fileName: String) {
        let short = (0..<10_000).map { "a\($0)" }.joined(separator: "\n")
        let tail = String(repeating: "x", count: 3_000_000)
        // 10,000 short lines, then one line of 3 MB after the 10,000th line break.
        let long = "<pre class=\"surimono-plain\">" + short + "\n" + tail + "</pre>"
        let other = PlainTextConverter.convert(short + "\nchanged", fileName: fileName).body
        let head = short.unicodeScalars.count + 1
        var visited = 0
        #expect(FragmentChanges.marks(from: other, to: long, visited: &visited).isEmpty)
        // Only the new text, up to the break that shows it is too long; the old text is not read at all.
        #expect(visited == head)
        visited = 0
        #expect(FragmentChanges.marks(from: long, to: other, visited: &visited).isEmpty)
        #expect(visited == head)
        // Both too long: the new one is read to its 10,000th break, the old one not at all.
        let longer = "<pre class=\"surimono-plain\">" + short + "\n" + tail + "y</pre>"
        visited = 0
        #expect(FragmentChanges.marks(from: long, to: longer, visited: &visited).isEmpty)
        #expect(visited == head)
        // At the limit both are read to the end, and the changed line is found.
        let atLimit = PlainTextConverter.convert(short, fileName: "a.txt").body
        let edited = PlainTextConverter.convert(short + "!", fileName: "a.txt").body
        visited = 0
        #expect(
            FragmentChanges.marks(from: atLimit, to: edited, visited: &visited) == [.init(blockID: "lines-9999-9999")])
        #expect(visited == short.unicodeScalars.count * 2 + 1)
    }

    @Test("色の閉じタグの直後に結合文字があっても、行ごとに比べて変えた行だけに印を付ける")
    func combiningMarkAfterTag() {
        // The comment ends and the text goes on with a combining acute accent: `</span>` + U+0301.
        let old = PlainTextConverter.convert("<a>\n<!-- c -->\u{301}text\n<b>1</b>\n", fileName: "a.xml").body
        #expect(old.contains("--&gt;</span>\u{301}text"))
        let new = PlainTextConverter.convert("<a>\n<!-- c -->\u{301}text\n<b>2</b>\n", fileName: "a.xml").body
        let only = marks(old, new)
        #expect(only == [.init(blockID: "lines-2-2")])
        let marked = FragmentChanges.identifyingBlocks(in: new, for: only)
        #expect(marked.contains("<span data-surimono-block=\"lines-2-2\">&lt;<span class=\"hl-tag\">b</span>"))
        #expect(marked.contains("--&gt;</span>\u{301}text\n"))
        // The line with the mark itself can be the changed one.
        let accent = PlainTextConverter.convert("<a>\n<!-- c -->\u{302}text\n<b>1</b>\n", fileName: "a.xml").body
        #expect(marks(old, accent) == [.init(blockID: "lines-1-1")])
        #expect(
            FragmentChanges.identifyingBlocks(in: accent, for: [.init(blockID: "lines-1-1")]).unicodeScalars.count
                == accent.unicodeScalars.count + "<span data-surimono-block=\"lines-1-1\"></span>".unicodeScalars.count)
    }

    @Test("閉じていないコメントの中で終わる文書でも、印を付けた HTML は末尾の改行を保つ")
    func trailingNewlineInsideSpan() {
        let new = PlainTextConverter.convert("let a = 1\n/* open\nstill open\n", fileName: "a.swift").body
        #expect(new.hasSuffix("still open\n</span></pre>"))
        let old = PlainTextConverter.convert("let a = 0\n/* open\nstill open\n", fileName: "a.swift").body
        let only = marks(old, new)
        #expect(only == [.init(blockID: "lines-0-0")])
        #expect(
            FragmentChanges.identifyingBlocks(in: new, for: only) == """
                <pre class="surimono-source"><span data-surimono-block="lines-0-0"><span class="hl-keyword">let</span> a = <span class="hl-number">1</span></span>
                <span class="hl-comment">/* open</span>
                <span class="hl-comment">still open</span>
                </pre>
                """)
    }

    @Test("色なしの文書に最初の色付きの語が現れても、末尾の行ではなく変えた行だけに印を付ける")
    func firstColoredToken() {
        let old = PlainTextConverter.convert("a b\nc d\ne f\n", fileName: "a.swift").body
        #expect(!old.contains("<span"))
        let new = PlainTextConverter.convert("a b\nlet d\ne f\n", fileName: "a.swift").body
        #expect(new.contains("<span"))
        #expect(marks(old, new) == [.init(blockID: "lines-1-1")])
        #expect(marks(new, old) == [.init(blockID: "lines-1-1")])
    }

    @Test("色付きの行に印を付けて戻した HTML は、span を除けば元の本文と同じ")
    func identifyingKeepsText() {
        let text = "/* a\n\n<b> & \"c\"\n*/\nlet d = 1\n\n"
        let html = PlainTextConverter.convert(text, fileName: "a.swift").body
        let marked = FragmentChanges.identifyingBlocks(in: html, for: [.init(blockID: "lines-2-2")])
        func stripped(_ html: String) -> String {
            html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        }
        #expect(stripped(marked) == stripped(html))
        #expect(stripped(marked) == "/* a\n\n&lt;b&gt; &amp; &quot;c&quot;\n*/\nlet d = 1\n\n")
        #expect(marked.contains("<span data-surimono-block=\"lines-2-2\"><span class=\"hl-comment\">&lt;b&gt;"))
    }

    @Test("色付きの JSON でも行の削除は隣の行に短い印を付ける")
    func coloredDeletion() {
        let old = PlainTextConverter.convert("{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n", fileName: "a.json").body
        let new = PlainTextConverter.convert("{\n  \"a\": 1,\n  \"c\": 3\n}\n", fileName: "a.json").body
        let change = marks(old, new)
        #expect(change == [.init(blockID: "lines-2-2", isShort: true)])
    }

    @Test("CSVのセルの変更と行の挿入はそれぞれ該当する一行だけに印を付ける")
    func csv() {
        let old = CSVConverter.convert("項目,数\n赤,1\n青,2").body
        for input in ["項目,数\n赤,8\n青,2", "項目,数\n黄,3\n赤,1\n青,2"] {
            let new = CSVConverter.convert(input).body
            let change = marks(old, new)
            #expect(change == [.init(blockID: "fragment-1")])
            #expect(FragmentChanges.identifyingBlocks(in: new, for: change).contains("<tr data-surimono-block="))
        }
    }

    @Test("入れ子のリストは変更した最も内側の項目に印を付ける")
    func lists() {
        for body in ["<ol><li>A</li><li>X</li></ol>", "<ul><li>親<ul><li>A</li><li>X</li></ul></li></ul>"] {
            let new = body.replacingOccurrences(of: ">X<", with: ">Y<")
            let change = marks(body, new)
            #expect(change.count == 1)
            if let id = change.first?.blockID {
                #expect(
                    FragmentChanges.identifyingBlocks(in: new, for: change)
                        == new.replacingOccurrences(of: "<li>Y", with: "<li data-surimono-block=\"\(id)\">Y"))
            }
        }
    }

    @Test("囲みをたどって表の一行を見つけ定義は語と説明を一組として扱う")
    func containers() {
        let html =
            "<section><details><blockquote><figure><div><table><tbody><tr><td>A</td></tr><tr><td>X</td></tr></tbody></table></div></figure></blockquote></details></section>"
        let new = html.replacingOccurrences(of: ">X<", with: ">Y<")
        let changed = marks(html, new)
        #expect(changed == [.init(blockID: "fragment-1")])
        #expect(
            FragmentChanges.identifyingBlocks(in: new, for: changed).contains(
                "<tr data-surimono-block=\"fragment-1\"><td>Y"))
        let definitions = "<dl><dt>A</dt><dd>B</dd><dt>C</dt><dd>D</dd></dl>"
        let edited = definitions.replacingOccurrences(of: ">D<", with: ">E<")
        let pair = marks(definitions, edited)
        #expect(pair == [.init(blockID: "fragment-1")])
        #expect(
            FragmentChanges.identifyingBlocks(in: edited, for: pair).contains(
                "<dt data-surimono-block=\"fragment-1\">C</dt><dd data-surimono-block=\"fragment-1\">E</dd>"))
    }

    @Test("五千段落の局所編集を検出し差分の計算量が上限を超えると印を省く")
    func large() {
        let body = (0..<5000).map { "<p>\($0)</p>" }.joined()
        #expect(marks(body, body.replacingOccurrences(of: ">2500<", with: ">編集<")) == [.init(blockID: "fragment-2500")])
        #expect(marks(body, body.replacingOccurrences(of: "<p>", with: "<p>X")).isEmpty)
    }
}
