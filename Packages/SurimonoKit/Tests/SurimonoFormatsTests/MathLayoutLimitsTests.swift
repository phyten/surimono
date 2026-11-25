import SwaTex
import Testing

@testable import SurimonoFormats

struct MathLayoutLimitsTests {
    private func accepts(_ source: String) throws -> Bool {
        try StackSpace.onLargeStack { MathLayoutLimits.accepts(try parseLaTeX(source)) }
    }

    @Test("寸法は em に換算し、負・非有限・単位の境界を組版前に調べる")
    func measurements() throws {
        #expect(try accepts(#"\kern40960pt"#))
        #expect(try !accepts(#"\kern-40961pt"#))
        #expect(try !accepts(#"\hspace{1450cm}"#))
        for value in [Double.infinity, -.infinity, .nan, .greatestFiniteMagnitude] {
            let bad = ParseNode(.kern(dimension: .init(number: value, unit: "em")), mode: .math)
            #expect(!MathLayoutLimits.accepts([bad]))
        }
    }

    @Test(
        "罫線・分数・上下移動・行間の寸法を子ノードでも見落とさない",
        arguments: [
            #"\left|\rule{0pt}{4097em}\right|"#, #"\sqrt{\rule[-4097em]{1pt}{1pt}}"#,
            #"\rule{4097em}{1pt}"#, #"\raisebox{-4097em}{x}"#, #"\genfrac{}{}{4097em}{}{1}{2}"#,
            #"{1 \above 4097em 2}"#, #"x_{\hskip 4097em}"#, #"\mkern 100000mu"#,
            #"\begin{matrix}x\\[4097em]y\end{matrix}"#,
        ])
    func dimensionInTree(_ formula: String) throws {
        #expect(try !accepts(formula))
    }

    @Test("数式内の CSS・リンクは組版前に拒否し、捨てられる HTML 属性は出力に現れない")
    func htmlExtensions() throws {
        for source in [
            #"\htmlStyle{color:red}{x}"#, #"\htmlStyle{font-size:5000em;font-size:1em}{x}"#,
            #"\href{https://example.invalid}{x}"#, #"\url{https://example.invalid}"#,
        ] {
            #expect(try !accepts(source))
        }
        #expect(MathRenderer.html(#"\includegraphics{x.png}"#, display: false) == nil)
        for command in ["htmlClass", "htmlId", "htmlData"] {
            let html = try #require(MathRenderer.html("\\" + command + "{testmarker}{x}", display: false))
            // The untouched TeX is still present in the accessible source label.
            #expect(!html.contains(#"class="testmarker""#))
            #expect(!html.contains(#"id="testmarker""#))
            #expect(!html.contains("data-testmarker"))
        }
    }

    @Test("倍率は上下両端を検査し、拡大する組版と描画の仕事量を別々に制限する")
    func composedWork() throws {
        func nested(_ name: String, _ depth: Int) -> String {
            (0..<depth).reduce("x") { body, _ in "\\" + name + "{" + body + "}" }
        }
        #expect(try accepts(nested("pmb", 3)))
        #expect(try !accepts(nested("pmb", 15)))
        #expect(try accepts(nested("tiny", 3)))
        #expect(try !accepts(nested("tiny", 17)))
        #expect(try !accepts(nested("Huge", 15)))
        #expect(try accepts(#"\left( a \middle| b \right)"#))
        #expect(try !accepts(#"\left( a {\Huge \middle|} b \right)"#))
        #expect(try accepts(#"\begin{array}{:c}1\\\hdashline 2\end{array}"#))
        #expect(try accepts(#"\begin{array}{::::c}x\end{array}{\kern4096em}"#))
        #expect(try !accepts(#"\begin{array}{cccc}\rule{4096em}{1pt}\\\hdashline\hdashline\hdashline x\end{array}"#))
    }

    @Test("伸縮パスと組版中の累積寸法は一式で共有する")
    func constructionWork() throws {
        let accent = try parseLaTeX(#"\widehat{x}"#)
        let repeated = Array(repeating: accent, count: 256).flatMap { $0 }
        #expect(MathLayoutLimits.accepts(repeated))
        #expect(!MathLayoutLimits.accepts(repeated + accent))
        let large = try parseLaTeX(#"\kern4096em"#)
        #expect(!MathLayoutLimits.accepts(Array(repeating: large, count: 125).flatMap { $0 }))
    }

    @Test("実際のボックスでも破線の刻み・距離・パス命令を表示リスト生成前に確かめる")
    func concreteBoxes() {
        func ruled(_ thickness: Double, _ height: Double) -> LayoutBox {
            let array = ArrayLayout(
                cells: [], colWidths: [], colAligns: [], rowHeights: [], rowDepths: [],
                track: .init(columnXs: [], rules: [.init(x: 0, isDashed: true)], width: 1),
                offset: 0, ruleThickness: thickness)
            return LayoutBox(width: 1, height: height, depth: 0, content: .array(array))
        }
        #expect(MathDisplayLimits.accepts(ruled(0.04, 1)))
        for thickness in [0, -1, .leastNonzeroMagnitude, .infinity, .nan] {
            #expect(!MathDisplayLimits.accepts(ruled(thickness, 1)))
        }
        #expect(!MathDisplayLimits.accepts(ruled(0.04, 20_000)))
        let commands = [PathCommand](repeating: .close, count: MathLayoutLimits.maximumDrawWork)
        let path = LayoutBox(width: 1, height: 1, depth: 0, content: .svgPath(commands: commands, fill: true))
        #expect(!MathDisplayLimits.accepts(path))
        let scale = MathLayoutLimits.minimumScale
        for factor in [scale, scale / 2] {
            let box = LayoutBox(
                width: 1, height: 1, depth: 0, content: .scaled(body: ruled(0.04, 1), childScale: factor))
            #expect(MathDisplayLimits.accepts(box) == (factor == scale))
        }
    }

    @Test("報告された深さと列指定を持つ構文木を組版に渡さない")
    func reviewedTreeSizes() {
        func node(_ kind: ParseNode.Kind) -> ParseNode { ParseNode(kind, mode: .math) }
        let x = node(.mathOrd(text: "x"))
        let overlay = (0..<20).reduce(x) { child, _ in node(.pmb(mclass: "mord", body: [child])) }
        #expect(!MathLayoutLimits.accepts([overlay]))
        let style = node(.html(attributes: ["style": "color:blue"], body: [x]))
        let fences = (0..<6).reduce(style) { child, _ in
            node(.leftRight(body: [node(.middle(delim: "|")), child], left: "(", right: ")", rightColor: nil))
        }
        #expect(!MathLayoutLimits.accepts([fences]))
        let rule = node(.rule(shift: nil, width: .init(number: 0, unit: "pt"), height: .init(number: 4096, unit: "em")))
        var grid = ParseNode.ArrayInfo(body: [[rule]], rowGaps: [], hLinesBeforeRow: [])
        grid.cols = .init(repeating: .init(alignType: .separator, align: ":"), count: 512)
        #expect(!MathLayoutLimits.accepts([node(.array(grid))]))
    }

    @Test("疎な行列は空のセルを補った面積を全配列で共有し、上限ちょうどまで通す")
    func paddedCells() {
        let x = ParseNode(.mathOrd(text: "x"), mode: .math)
        func grid(_ rows: Int, _ columns: Int, cell: ParseNode) -> ParseNode {
            var body = [[ParseNode]](repeating: [x], count: rows)
            body[0] = [ParseNode](repeating: cell, count: columns)
            return ParseNode(.array(.init(body: body, rowGaps: [], hLinesBeforeRow: [])), mode: .math)
        }
        let half = grid(64, 64, cell: x)
        #expect(MathLayoutLimits.accepts([half, half]))
        #expect(!MathLayoutLimits.accepts([grid(1, 1, cell: half), half]))
        #expect(!MathLayoutLimits.accepts([grid(1_001, 2_048, cell: x)]))
    }

    @Test("配列の伸び・列間隔・タグ・証明木のラベルにも同じ制限を使う")
    func secondaryLayoutContent() {
        let x = ParseNode(.mathOrd(text: "x"), mode: .math)
        let bad = ParseNode(.kern(dimension: .init(number: -.infinity, unit: "mu")), mode: .math)
        var array = ParseNode.ArrayInfo(body: [[x]], rowGaps: [], hLinesBeforeRow: [])
        array.isCD = true
        array.body = [[bad]]
        #expect(!MathLayoutLimits.accepts([ParseNode(.array(array), mode: .math)]))
        array.body = [[x]]
        array.isCD = false
        array.tags = [.explicit([bad])]
        #expect(!MathLayoutLimits.accepts([ParseNode(.array(array), mode: .math)]))
        array.tags = nil
        array.cols = [.init(alignType: .align, postgap: .nan)]
        #expect(!MathLayoutLimits.accepts([ParseNode(.array(array), mode: .math)]))
        array.cols = nil
        array.arraystretch = 4_096
        #expect(!MathLayoutLimits.accepts([ParseNode(.array(array), mode: .math)]))
        var branch = ProofBranch(conclusion: [x], premises: [], leftLabel: [bad], lineStyle: .solid)
        #expect(!MathLayoutLimits.accepts([ParseNode(.proofTree(tree: branch), mode: .math)]))
        branch.leftLabel = nil
        for _ in 1..<32 { branch = ProofBranch(conclusion: [x], premises: [branch], lineStyle: .solid) }
        #expect(MathLayoutLimits.accepts([ParseNode(.proofTree(tree: branch), mode: .math)]))
        branch = ProofBranch(conclusion: [x], premises: [branch], lineStyle: .solid)
        #expect(!MathLayoutLimits.accepts([ParseNode(.proofTree(tree: branch), mode: .math)]))
    }

    @Test("通常の文書変換でもマクロ展開後に寸法を検査し、次の式と末尾の本文まで描く")
    func normalDocument() throws {
        // Keep the regression safe even if the validation boundary is accidentally removed.
        let parsed = try parseLaTeX(#"\left|\rule{0pt}{100000000000000000000em}\right|"#)
        try #require(!MathLayoutLimits.accepts(parsed))
        let document = #"""
            \newcommand{\heighttest}{100000000000000000000em}
            \begin{document}
            Before $\left|\rule{0pt}{\heighttest}\right|$ then $a+b$. Tail.
            \end{document}
            """#
        let html = LaTeXConverter.convert(document).body
        #expect(html.contains("class=\"math-error\""))
        #expect(html.contains(#"\heighttest"#))
        #expect(html.components(separatedBy: "<svg ").count - 1 == 1)
        #expect(html.contains(#"aria-label="a+b""#))
        #expect(html.contains("Tail."))
    }

    @Test("二十行二十列の行列と通常の罫線・空き・大きな括弧を組版する")
    func printableMath() throws {
        let row = Array(repeating: "x", count: 20).joined(separator: "&")
        let matrix = #"\begin{matrix}"# + Array(repeating: row, count: 20).joined(separator: #"\\"#) + #"\end{matrix}"#
        for formula in [matrix, #"\rule{2cm}{0.4pt}"#, #"\hspace{3em}x"#, #"\Bigg( x \Bigg)"#] {
            let html = try #require(MathRenderer.html(formula, display: true))
            #expect(html.contains("<svg "))
        }
    }
}
