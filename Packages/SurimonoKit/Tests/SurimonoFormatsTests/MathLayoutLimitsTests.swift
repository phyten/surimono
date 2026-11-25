import SwaTex
import Testing

@testable import SurimonoFormats

struct MathLayoutLimitsTests {
    private func accepts(_ source: String) throws -> Bool {
        MathLayoutLimits.accepts(try parseLaTeX(source))
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

    @Test("倍率は入れ子の積と局所座標の両方で検査する")
    func scales() throws {
        #expect(try accepts(#"\htmlStyle{font-size:32em}{\htmlStyle{font-size:128em}{x}}"#))
        #expect(try !accepts(#"\htmlStyle{font-size:32em}{\htmlStyle{font-size:2064px}{x}}"#))
        #expect(try !accepts(#"\htmlStyle{font-size:0.01em}{\htmlStyle{font-size:4097em}{x}}"#))
        #expect(try !accepts(#"\htmlStyle{font-size:64em}{\rule{100em}{1pt}}"#))
        let percent = ParseNode(.html(attributes: ["style": "font-size:409700%"], body: []), mode: .math)
        #expect(!MathLayoutLimits.accepts([percent]))
        #expect(try !accepts(#"\Huge{\htmlStyle{font-size:2048em}{x}}"#))
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
