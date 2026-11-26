import Foundation
import SwaTex
import Testing

@testable import SurimonoFormats

struct PreviewMathExpansionTests {
    @Test("置換で消える空白・結合する文字を拒み、区切りだけを足した制御綴りは保つ")
    func serializedTokens() throws {
        for (definitions, formula) in [
            (#"\def\joinword#1{\text{\TeX#1}}"#, #"\joinword{ code}"#),
            (#"\def\joinword#1{\text{a #1}}"#, #"\joinword{ b}"#),
            (#"\def\joinword#1{\ #1}"#, #"\joinword{ b}"#),
            (#"\def\letterword{x}"#, "\\letterword\u{0301}"),
        ] {
            var expansion = PreviewMathExpansion()
            #expect(throws: PreviewMathExpansion.Refusal.unsupported) {
                try expansion.expand(formula, definitions: definitions)
            }
        }
        var expansion = PreviewMathExpansion()
        #expect(try expansion.expand(#"\joinword{x}"#, definitions: #"\def\joinword#1{\alpha#1}"#) == #"\alpha x"#)
        let spaced = try expansion.expand(#"\spacedword"#, definitions: #"\def\spacedword{x\ }"#)
        #expect(try PreviewMathExpansion.tokens(spaced) == ["x", #"\ "#])
        #expect(!spaced.hasSuffix(" ") && expansion.outputBytes == spaced.utf8.count)
        let dollars = try expansion.expand(#"\wrapped"#, definitions: #"\def\wrapped{$x$}"#)
        #expect(try PreviewMathExpansion.tokens(dollars) == ["$", "x", "$"])
        #expect(!dollars.hasPrefix("$") && !dollars.hasSuffix("$"))
    }

    @Test("置換末尾の制御空白は SwaTex に定義を直接渡した場合と同じ SVG になる")
    func trailingControlSpaceSVG() throws {
        let definition = #"\def\spacedword{x\ }"#
        let formula = #"\spacedword"#
        func svg(_ input: String) throws -> String {
            let nodes = try parseLaTeX(input)
            let box = layout(nodes, options: LayoutOptions(style: .text))
            return renderToSVG(toDisplayList(box), SVGOptions())
        }
        var expansion = PreviewMathExpansion()
        let expanded = try expansion.expand(formula, definitions: definition)
        let reference = try svg(definition + formula)
        #expect(try svg(expanded).utf8.elementsEqual(reference.utf8))
    }

    @Test("置換で両端に現れたドル記号は SwaTex が元の定義と同じく構文エラーにする")
    func expandedDollarDelimiters() throws {
        let definition = #"\def\wrapped{$x$}"#
        let formula = #"\wrapped"#
        var expansion = PreviewMathExpansion()
        let expanded = try expansion.expand(formula, definitions: definition)
        #expect(throws: ParseError.self) { try parseLaTeX(definition + formula) }
        #expect(throws: ParseError.self) { try parseLaTeX(expanded) }
    }

    @Test("制御綴り直後と連続する空白は変更前の画像または式の原文で表示する")
    func spacesInDocuments() throws {
        for (definitions, formula) in [
            (#"\def\joinword#1{\text{\TeX#1}}"#, #"\joinword{ code}"#),
            (#"\def\joinword#1{\text{a #1}}"#, #"\joinword{ b}"#),
        ] {
            let parsed = try parseLaTeX(definitions + formula)
            for display in [false, true] {
                let delimiter = display ? "$$" : "$"
                let tex = delimiter + formula + delimiter
                // Markdown carries the declaration inside the math delimiters.
                let md = delimiter + definitions + formula + delimiter
                try PreviewConversion.$current.withValue(PreviewConversion(deadline: .now + .seconds(10))) {
                    for (body, source, label) in [
                        (MarkdownConverter.convert(md).body, md, definitions + formula),
                        (
                            LaTeXConverter.convert(definitions + #"\begin{document}"# + tex + #"\end{document}"#).body,
                            tex, formula
                        ),
                    ] {
                        let reference = try #require(
                            MathRenderer.renderParsed(parsed, source: label, original: label, display: display))
                        if body.contains("math-error") {
                            #expect(
                                body.contains(MathRenderer.fallback(source, display: display))
                                    && !body.contains("<svg "))
                        } else {
                            #expect(body.utf8.firstRange(of: reference.utf8) != nil)
                        }
                    }
                }
            }
        }
    }

    @Test("字句規則を変える命令は利用者定義の中でも拒み、改行を含む URL は原文のまま残す")
    func contextualLexing() {
        let url = "https://example.test/a%20b\nc"
        let definitions = #"\def\word{x}"#
        let formula = #"\word+\url{"# + url + "}"
        for (source, preamble) in [
            (formula, definitions), (#"\href{"# + url + "}{x}", ""), (#"\url{a}"#, ""),
            (#"\outerword{"# + url + "}", #"\def\innerword{\href}\def\outerword{\innerword}"#),
            (#"\outerword"#, #"\def\outerword{\url{a}}"#), (#"\verb|%~|"#, ""), (#"\verb*|%~|"#, ""),
        ] {
            var expansion = PreviewMathExpansion()
            #expect(throws: PreviewMathExpansion.Refusal.unsupported) {
                try expansion.expand(source, definitions: preamble)
            }
            #expect(expansion.steps == 0 && expansion.scheduledBytes == 0 && expansion.outputBytes == 0)
        }
        PreviewConversion.$current.withValue(PreviewConversion(deadline: .now + .seconds(10))) {
            for delimiter in ["$", "$$"] {
                let math = delimiter + formula + delimiter
                let tex = definitions + #"\begin{document}"# + math + #" then $a+b$.\end{document}"#
                let html = LaTeXConverter.convert(tex).body
                #expect(
                    html.contains(MathRenderer.fallback(math, display: delimiter == "$$"))
                        && html.contains(#"aria-label="a+b""#))
            }
            for source in [definitions + formula, #"\url{"# + url + "}"] {
                let math = "$$" + source + "$$"
                let html = MarkdownConverter.convert(math + "\n\nThen $a+b$.").body
                #expect(
                    html.contains(MathRenderer.fallback(math, display: true)) && html.contains(#"aria-label="a+b""#))
            }
        }
    }

    @Test("引数を二度使うマクロの入れ子は実際に積んだトークンと出力量で打ち切る")
    func doubledArguments() {
        var expansion = PreviewMathExpansion()
        let expression = String(repeating: #"\twice{"#, count: 18) + "x" + String(repeating: "}", count: 18)
        #expect(throws: PreviewMathExpansion.Refusal.steps) {
            try expansion.expand(expression, definitions: #"\def\twice#1{#1#1}"#)
        }
        #expect(expansion.steps == 1_024)
        #expect(expansion.peakPendingBytes <= 8_192 && expansion.outputBytes <= 8_192)
        #expect(expansion.scheduledBytes <= 65_536)
    }

    @Test("引数なしの倍増列も再帰と深さの上限も構文木を作る前に拒否する")
    func expandingChain() {
        let names = Array("abcdefghijklmnopqrst").map { "\\op" + String($0) }
        var declarations = #"\def\opa{x}"#
        for (a, b) in zip(names, names.dropFirst()) { declarations += "\\def\(b){\(a)\(a)}" }
        var expansion = PreviewMathExpansion()
        #expect(throws: PreviewMathExpansion.Refusal.steps) {
            try expansion.expand(#"\opt"#, definitions: declarations)
        }
        #expect(expansion.steps == 1_024)
        #expect(expansion.scheduledBytes <= 65_536 && expansion.peakPendingBytes <= 8_192)
        var cycle = PreviewMathExpansion()
        #expect(throws: PreviewMathExpansion.Refusal.recursion) {
            try cycle.expand(#"\firstop"#, definitions: #"\def\firstop{\secondop}\def\secondop{\firstop}"#)
        }
        var depth = PreviewMathExpansion()
        #expect(throws: PreviewMathExpansion.Refusal.depth) {
            try depth.expand(
                "\\idop{" + String(repeating: "{", count: 33) + "x" + String(repeating: "}", count: 34),
                definitions: #"\def\idop#1{#1}"#)
        }
    }

    @Test("置換引数を積む前にバイト予算を検査する")
    func stackBytes() {
        var expansion = PreviewMathExpansion()
        let input = "\\copyop{" + String(repeating: "x", count: 3_000) + "}"
        #expect(throws: PreviewMathExpansion.Refusal.size) {
            try expansion.expand(input, definitions: #"\def\copyop#1{#1#1#1}"#)
        }
        #expect(expansion.steps == 1 && expansion.peakPendingBytes == 8_192 && expansion.outputBytes == 0)
    }

    @Test("小さなスタックで長い引数を渡し続けても累計の書き込み量で打ち切る")
    func cumulativeBytes() {
        let nested =
            String(repeating: #"\carry{"#, count: 24) + String(repeating: "x", count: 3_200)
            + String(repeating: "}", count: 24)
        var expansion = PreviewMathExpansion()
        #expect(throws: PreviewMathExpansion.Refusal.size) {
            try expansion.expand(nested, definitions: #"\def\carry#1{#1}"#)
        }
        #expect(expansion.peakPendingBytes < 4_096 && expansion.outputBytes == 0)
        #expect((65_531...65_536).contains(expansion.scheduledBytes))
        #expect(expansion.steps < 24)
    }

    @Test("グループ内の定義・間接指定・組み込みの書き換えはその式だけ原文になる")
    func unsupported() {
        for (source, declarations) in [
            (#"{\def\word{x}\word}+y"#, ""), (#"\word"#, #"\let\word=\alpha"#),
            (#"\word{x},"#, #"\def\word#1,{#1}"#), (#"\word"#, #"\def\word{\csname alpha\endcsname}"#),
            (#"\expandafter x"#, ""), (#"\R"#, #"\def\R{z}"#), (#"\frac"#, #"\def\frac{x}"#),
            (#"\argmax"#, #"\DeclareMathOperator{\argmax}{other}"#),
            (#"\R"#, #"\DeclareMathOperator{\R}{\mathbb{R}}"#), (#"\alpha"#, #"\def\alpha{x}"#),
            (#"\mathbin"#, #"\def\mathbin{x}"#),
        ] {
            var expansion = PreviewMathExpansion()
            #expect(throws: PreviewMathExpansion.Refusal.unsupported) {
                try expansion.expand(source, definitions: declarations)
            }
        }
        let source = #"\begin{document}Before $a$ and ${\def\word{x}\word}+y$ then $b$.\end{document}"#
        let body = PreviewConversion.$current.withValue(PreviewConversion(deadline: .now + .seconds(10))) {
            LaTeXConverter.convert(source).body
        }
        #expect(body.contains("math-error") && body.components(separatedBy: "<svg ").count == 3)
    }

    @Test("宣言をグループの外へ持ち出さず、未対応の定義が及ぶ式だけ原文で示す")
    func declarationScope() {
        let request = PreviewConversion(deadline: .now + .seconds(5))
        PreviewConversion.$current.withValue(request) {
            let org = OrgConverter.convert("#+LATEX_HEADER: {\\def\\alpha{x}}\n\n$a$ and $\\alpha$.").body
            #expect(org.contains(#"<code class="math-error">$\alpha$</code>"#))
            let tex = LaTeXConverter.convert(
                #"\newcommand{\wordop}{x}\begin{document}$\wordop$ {\renewcommand{\wordop}{y}$\wordop$} $\wordop$\end{document}"#
            ).body
            #expect(tex.components(separatedBy: "<svg ").count - 1 == 2)
            #expect(tex.contains("math-error"))
        }
    }

    @Test("提供済みの名前を保ち、再宣言・九個の引数・引数を取る別名を展開する")
    func signatures() throws {
        let defs =
            #"\newcommand{\wrap}[1]{#1}\providecommand{\wrap}{z}\renewcommand{\wrap}[1]{(#1)}\def\alias{\wrap}\def\nine#1#2#3#4#5#6#7#8#9{#9#1}"#
        var expansion = PreviewMathExpansion()
        #expect(try expansion.expand(#"\alias{x}+\nine123456789"#, definitions: defs) == "(x)+91")
    }

    @Test("組み込みの特殊な展開回数をユーザーマクロの展開後にも数える")
    func specialBuiltins() throws {
        for command in [#"\tmspace"#, #"\Braket"#, #"\set"#, #"\Set"#] {
            var allowed = PreviewMathExpansion()
            #expect(
                try allowed.expand(String(repeating: command, count: 4), definitions: "")
                    == String(repeating: command, count: 4))
            var expansion = PreviewMathExpansion()
            #expect(throws: PreviewMathExpansion.Refusal.size) {
                try expansion.expand(
                    #"\wrapped"#, definitions: "\\def\\wrapped{" + String(repeating: command, count: 5) + "}")
            }
        }
        var chemistry = PreviewMathExpansion()
        #expect(try chemistry.expand(#"\ce{H2O}+\pu{3 kg}"#, definitions: "") == #"\ce{H2O}+\pu{3 kg}"#)
        var bars = PreviewMathExpansion()
        #expect(throws: PreviewMathExpansion.Refusal.size) {
            try bars.expand("\\Braket{" + String(repeating: "|", count: 65) + "}", definitions: "")
        }
        for command in [#"\bra@ket"#, #"\bra@set"#, #"\ce{\alpha}"#, #"\pu"#] {
            var expansion = PreviewMathExpansion()
            #expect(throws: PreviewMathExpansion.Refusal.unsupported) { try expansion.expand(command, definitions: "") }
        }
    }

    @Test(
        "論文用の宣言と省略可能引数は通常の LaTeX 表示と同じ SVG を組む",
        arguments: [
            (#"\newcommand{\R}{\mathbb{R}}"#, #"\R"#),
            (#"\newcommand{\norm}[1]{\left\lVert #1 \right\rVert}"#, #"\norm{x+y}"#),
            (#"\DeclareMathOperator{\argmax}{arg\,max}"#, #"\argmax_{x} f(x)"#),
            (#"\newcommand{\pair}[2][x]{#1+#2}"#, #"\pair{y}+\pair[z]{w}"#),
        ])
    func paperMacros(declaration: String, expression: String) throws {
        let source = declaration + "\n\\begin{document}\n\\[\(expression)\\]\n\\end{document}"
        func svg(_ html: String) throws -> String {
            let start = try #require(html.range(of: "<svg "))
            let end = try #require(html.range(of: "</svg>", range: start.upperBound..<html.endIndex))
            // The accessible label retains the original call in Finder. Compare all painting and geometry.
            return String(html[start.lowerBound..<end.upperBound]).replacingOccurrences(
                of: #" (aria-label|data-formula-source)="[^"]*""#, with: "", options: .regularExpression)
        }
        let printed = try svg(LaTeXConverter.convert(source).body)
        let preview = PreviewConversion.$current.withValue(PreviewConversion(deadline: .now + .seconds(10))) {
            LaTeXConverter.convert(source).body
        }
        #expect(try svg(preview) == printed)
    }
}
