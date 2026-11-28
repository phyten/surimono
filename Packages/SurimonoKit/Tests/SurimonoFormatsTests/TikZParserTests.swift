import Foundation
import Testing

@testable import SurimonoFormats

struct TikZParserTests {
    private func items(_ body: String, styles: String = "") throws -> [[String: Any]] {
        let scene = try TikZParser.scene(body, styles: styles, colors: [:]) { "<b>" + $0 + "</b>" }
        return try #require(scene["items"] as? [[String: Any]])
    }

    @Test("基本の線分は単位を保持した二点と解決済みの色になる")
    func segment() throws {
        let values = try items(#"\draw[blue!30] (0,0)--(1cm,2pt);"#)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        #expect(
            String(decoding: data, as: UTF8.self)
                == ##"[{"kind":"path","ops":[{"op":"M","p":{"x":"0","y":"0"}},{"op":"L","p":{"x":"1cm","y":"2pt"}}],"style":{"color":"#b3b3ff","draw":"#b3b3ff","fill":"none"}}]"##
        )
    }

    @Test("スコープ内の追記スタイルとノードの既定スタイルを順番に解決する")
    func scopedStyles() throws {
        let values = try items(
            #"\begin{scope}\tikzset{box/.append style={fill=green!20}}\node[box] (a) {one};\end{scope}\node[box,right=of a] {two};"#,
            styles: "box/.style={draw},every node/.style={minimum width=1cm}")
        let styles = values.compactMap { $0["style"] as? [String: Any] }
        #expect(styles.count == 2)
        #expect(styles[0]["fill"] as? String == "#ccffcc")
        #expect(styles[1]["fill"] as? String == "none")
        #expect(styles[1]["minimum width"] as? String == "1cm")
    }

    @Test(
        "途中の未対応キーや命令は図を丸ごと退ける",
        arguments: [
            #"\draw (0,0)--(1,0);\pic {angle=A--B--C};"#,
            #"\draw[decorate,decoration={text along path}] (0,0)--(1,1);"#,
            #"\fill[pattern=dots] (0,0) rectangle (1,1);"#,
            #"\node[trapezium] {sample};"#, #"\draw (A)--(1,2);"#, #"\draw (0,0)--(nan,2);"#,
            #"\draw[thin=bogus] (0,0)--(1,2);"#,
        ])
    func rejects(_ source: String) {
        #expect(throws: TikZError.self) { try items(source) }
    }
}

extension TikZParserTests {
    @Test("単純な木は親を基準に兄弟を等間隔に配置し、辺を三本つなぐ")
    func tree() throws {
        let values = try items(
            #"\node {root}[level distance=12mm,sibling distance=30mm] child {node {left} child {node {leaf}}} child {node {right}};"#
        )
        let nodes = values.filter { $0["kind"] as? String == "node" }
        #expect(nodes.count == 4)
        #expect(values.filter { $0["kind"] as? String == "path" }.count == 3)
        let left = try #require((nodes[1]["at"] as? [String: Any])?["b"] as? [String: String])
        #expect(left == ["x": "-15mm", "y": "-12mm"])
    }

    @Test("図とスコープで指定した木の間隔を子の配置に使う")
    func treeDistancesFromPicture() throws {
        let tree = #"\node {root} child {node {a}} child {node {b}};"#
        let picture = try items("[level distance=15mm,sibling distance=37mm]" + tree)
        let left = try #require((picture[1]["at"] as? [String: Any])?["b"] as? [String: String])
        #expect(left == ["x": "-18.5mm", "y": "-15mm"])
        let scoped = try items(#"\begin{scope}[sibling distance=2cm,level distance=1cm]"# + tree + #"\end{scope}"#)
        let nodes = scoped.filter { $0["kind"] as? String == "node" }
        let right = try #require((nodes[2]["at"] as? [String: Any])?["b"] as? [String: String])
        #expect(right == ["x": "1cm", "y": "-1cm"])
        #expect(nodes.allSatisfy { ($0["style"] as? [String: Any])?["sibling distance"] == nil })
    }

    @Test("段ごとの level スタイルはその段の子とその下に効く")
    func treeLevelStyles() throws {
        let values = try items(
            #"[level 1/.style={sibling distance=40mm},level 2/.style={sibling distance=10mm,level distance=8mm}]\node {r} child {node {a} child {node {c}} child {node {d}}} child {node {b}};"#
        )
        let nodes = values.filter { $0["kind"] as? String == "node" }
        let offsets = try nodes.dropFirst().map {
            try #require(($0["at"] as? [String: Any])?["b"] as? [String: String])
        }
        #expect(
            offsets == [
                ["x": "-20mm", "y": "-15mm"], ["x": "-5mm", "y": "-8mm"], ["x": "5mm", "y": "-8mm"],
                ["x": "20mm", "y": "-15mm"],
            ])
    }

    @Test("木の子や辺を飾るスタイルと、間隔以外を変える level スタイルは図を退ける")
    func treeRejectsUnreadStyles() {
        let tree = #"\node {r} child {node {a}};"#
        for options in [
            "[edge from parent/.style={draw,red}]", "[every child node/.style={draw}]",
            "[level 1/.style={red}]", "[level/.style={sibling distance=60mm/#1}]",
        ] {
            #expect(throws: TikZError.self) { try items(options + tree) }
        }
    }

    @Test("折れ線・直交・弧・ベジェ・格子・相対座標は順序を保つ")
    func primitives() throws {
        let values = try items(
            #"\draw (0,0)-|++(1,2)|-+(3,4).. controls (1,1) and (2,2) .. (3,3) arc (90:180:1cm) grid[step=3mm] (5,6) --cycle;"#
        )
        let ops = try #require(values.first?["ops"] as? [[String: Any]])
        #expect(ops.compactMap { $0["op"] as? String } == ["M", "-|", "|-", "C", "arc", "grid", "Z"])
        #expect((ops[1]["p"] as? [String: String])?["relative"] == "++")
        #expect(ops[4]["rx"] as? String == "1cm")
    }

    @Test("経路上のラベルは端点と区間の中央を区別し、配置と矢尻を保つ")
    func labelAndArrow() throws {
        let values = try items(
            #"\node (a) {A};\node[right=of a] (b) {B};\draw[->,>={Latex[length=2.2mm]}] (a.north) to[bend left=25] node[below]{mid} (b.30) node[right]{end};"#
        )
        let line = try #require(values.last)
        let style = try #require(line["style"] as? [String: Any])
        #expect(style[">"] as? String == "Latex")
        #expect(style["tip length"] as? String == "2.2mm")
        let ops = try #require(line["ops"] as? [[String: Any]])
        #expect(ops[2]["segment"] as? Bool == true)
        #expect(ops[3]["segment"] == nil)
    }

    @Test("クリップと回転したパターン面をスコープ内だけに置く")
    func clipping() throws {
        let values = try items(
            #"\begin{scope}[rotate=30]\clip (0,0) ellipse (2 and 1);\fill[pattern=north east lines] (0,0) rectangle (2,1);\end{scope}"#
        )
        #expect(values.compactMap { $0["kind"] as? String } == ["scope", "clip", "path", "endScope"])
        #expect((values[2]["style"] as? [String: Any])?["pattern"] as? String == "north east lines")
    }

    @Test("二点の内分とベクトル加算、直交座標、極座標を区別する")
    func coordinates() throws {
        let values = try items(
            #"\coordinate (a) at (0,0);\coordinate (b) at (0:1cm);\coordinate (m) at ($(a)!.5!(b)$);\draw ($(m)+(0,.8)$)--(m |- a)--(b -| a);"#
        )
        #expect((values[1]["at"] as? [String: String]) == ["x": "1cm", "y": "0cm"])
        #expect((values[2]["at"] as? [String: Any])?["t"] as? Double == 0.5)
        let ops = try #require(values[3]["ops"] as? [[String: Any]])
        #expect(ops.compactMap { ($0["p"] as? [String: Any])?["calc"] as? String } == ["add", "|-", "-|"])
    }

    @Test("式と座標列から折れ線を作り、上限を超えたサンプルを拒む")
    func plots() throws {
        let values = try items(#"\draw plot[domain=0:2,samples=3] (\x,{\x^2});\draw plot coordinates {(0,0) (1,1)};"#)
        let curve = try #require(values[0]["ops"] as? [[String: Any]])
        #expect(curve.compactMap { ($0["p"] as? [String: String])?["y"] } == ["0", "1", "4"])
        #expect(throws: TikZError.self) { try items(#"\draw plot[samples=2001] (\x,\x);"#) }
    }
}

extension TikZParserTests {
    @Test("三点の角度は指定半径の弧と二等分線上の数式になる")
    func anglePic() throws {
        let values = try items(
            #"\coordinate (A) at (0,0);\coordinate (B) at (1,0);\coordinate (C) at (0,1);\pic[draw,angle radius=10pt,"$\alpha$"{angle eccentricity=1.4}] {angle=B--A--C};"#
        )
        let ops = try #require(values[3]["ops"] as? [[String: Any]])
        #expect(ops[0]["p"] as? [String: String] == ["x": "10pt", "y": "0pt"])
        #expect(ops[1]["end"] as? Double == 90)
        let label = try #require(values.last?["at"] as? [String: String])
        let x = try #require(Double((label["x"] ?? "").dropLast(2)))
        #expect(abs(x - 4.24264) < 0.0001)
    }

    @Test("位置決めと角を曲がる経路に名前付きスタイルと混色を重ねる")
    func flowchart() throws {
        let source = #"""
            [node distance=10mm and 12mm, >={Latex[length=2.2mm]}, every path/.style={line width=0.7pt}, block/.style={draw=paperblue,fill=paperblue!5,rounded corners,align=center,text width=25mm,minimum height=10mm,inner sep=3pt}, shade/.style={fill=#1!70!black}]
            \node[block] (a) {日本語\\\textbf{入力}};
            \node[block,right=of a] (b) {\texttt{B}};
            \node[block,shade=papergreen,below=18mm of b] (c) {三};
            \node[block,above right=8mm and 7mm of c] (d) {四};
            \draw[->,thick] (a.east)--(b.west);
            \draw[->,dashed] (b.south)|-++(-7mm,0)-|(c.north);
            \draw[->] (c) to[bend left=25] node[below]{次} (d);
            """#
        let result = try TikZParser.scene(
            source, styles: "", colors: ["paperblue": (0, 0, 1), "papergreen": (0, 1, 0)]
        ) { $0 }
        let values = try #require(result["items"] as? [[String: Any]])
        #expect(values.count == 7)
        let green = try #require(values[2]["style"] as? [String: Any])
        #expect(green["fill"] as? String == "#00b300")
        #expect(green["line width"] as? String == "0.7pt")
        let paint = try #require(values[4]["style"] as? [String: Any])
        #expect(paint["line width"] as? String == "0.8pt")
    }
}

extension TikZParserTests {
    @Test("図の色定義と別名はスコープを出ると元に戻る")
    func localColor() throws {
        let values = try items(
            #"\definecolor{paper}{HTML}{002244}\colorlet{tint}{paper!50!white}\begin{scope}\colorlet{tint}{red}\fill[tint] (0,0) circle (1);\end{scope}\fill[tint] (1,0) circle (1);"#
        )
        let fills = values.compactMap { ($0["style"] as? [String: Any])?["fill"] as? String }
        #expect(fills == ["#ff0000", "#8091a2"])
    }

    @Test("曲線へ未対応の角丸を付けた場合はその図を退ける")
    func roundedCurve() {
        #expect(throws: TikZError.self) {
            try items(#"\draw[rounded corners] (0,0) --(1,0).. controls (1,1) and (2,1) ..(3,2);"#)
        }
    }
}

extension TikZParserTests {
    @Test("行列の行・列・ラベルを保ち、行列名と一始まりの行列番号で結ぶ")
    func matrixCells() throws {
        let source = #"""
            \matrix (rack) [matrix of nodes,nodes={draw,minimum width=15mm},row sep=5mm,column sep=6mm]{
              A1 & \textbf{A2} & A3 \\
              {B1 \\ B} & B2 & B3 \\
            };
            \draw[-{Stealth},blue] (rack-1-2.south)--(rack-2-2.north);
            """#
        let values = try items(source)
        let matrix = try #require(values.first)
        #expect(matrix["kind"] as? String == "matrix")
        #expect(matrix["rowSep"] as? String == "5mm")
        #expect(matrix["columnSep"] as? String == "6mm")
        #expect(
            matrix["cells"] as? [[String]] == [
                ["<b>A1</b>", #"<b>\textbf{A2}</b>"#, "<b>A3</b>"],
                [#"<b>{B1 \\ B}</b>"#, "<b>B2</b>", "<b>B3</b>"],
            ])
        let cells = try #require(matrix["cellStyle"] as? [String: Any])
        #expect(cells["minimum width"] as? String == "15mm")
        #expect(cells["anchor"] as? String == "base")
        let ops = try #require(values.last?["ops"] as? [[String: Any]])
        #expect(ops[0]["p"] as? [String: String] == ["name": "rack-1-2", "anchor": "south"])
        #expect(ops[1]["p"] as? [String: String] == ["name": "rack-2-2", "anchor": "north"])
    }

    @Test(
        "行列の未対応の指定、空セル、存在しないセルへの接続は図全体を退ける",
        arguments: [
            #"\matrix {A};"#,
            #"\matrix (m)[matrix of nodes,nodes in empty cells]{A&&B\\};"#,
            #"\tikzset{row 1/.style={red}}\matrix (m)[matrix of nodes]{A & B \\};"#,
            #"\matrix (m)[matrix of nodes,row sep=-1mm]{A & B \\};"#,
            #"\matrix (m)[matrix of nodes]{A & B \\ C \\};"#,
            #"\matrix (m)[matrix of nodes]{A & B \\[2mm] C & D \\};"#,
            #"\matrix (m)[matrix of nodes]{A & |[red]|B \\};"#,
            #"\matrix (m)[matrix of nodes]{A & B \\};\draw (m-1-2)--(m-2-2);"#,
        ])
    func invalidMatrix(_ source: String) {
        #expect(throws: TikZError.self) { try items(source) }
    }
}
