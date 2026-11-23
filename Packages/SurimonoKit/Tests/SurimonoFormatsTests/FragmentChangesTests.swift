import SurimonoFormats
import Testing

struct FragmentChangesTests {
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
                <pre class="surimono-plain"><span class="hl-keyword">let</span> a = <span class="hl-number">1</span>
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
