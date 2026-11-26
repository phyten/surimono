import Foundation
import Testing

@testable import SurimonoFormats

struct AppMathInputTests {
    @Test("展開結果が枠に収まらない引数のコピーを積む前に拒む")
    func byteCounters() {
        var expansion = PreviewMathExpansion()
        let call = #"\copyword{"# + String(repeating: "x", count: 2_049) + "}"
        #expect(throws: PreviewMathExpansion.Refusal.size) {
            try expansion.expand(call, definitions: #"\def\copyword#1{#1#1#1#1}"#)
        }
        #expect(expansion.steps == 1)
        #expect(expansion.peakPendingBytes == 8_192)
        #expect(expansion.outputBytes == 0)
        #expect(expansion.scheduledBytes == call.utf8.count + 8_192)
    }

    @Test("区切り付き引数と引数なしの呼び出し先を計数できた式だけを元の定義で組む")
    func boundedNative() throws {
        let definitions = #"\def\leaf{x}\def\pick#1;{\leaf+#1}"#
        let formula = #"\pick y;"#
        let prepared = try #require(AppMathInput.prepare(formula, definitions: definitions))
        #expect(prepared.route == .boundedNative)
        #expect(prepared.input == definitions + formula)
        let html = try #require(MathRenderer.html(formula, display: false, macros: definitions))
        #expect(html.contains(">x</text>") && html.contains(">y</text>"))
        #expect(!NativeMathBound.accepts(formula, definitions: #"\def\leaf{\leaf}\def\pick#1;{\leaf+#1}"#))
        #expect(!NativeMathBound.accepts(formula, definitions: #"\def\pick#1;{\csname x\endcsname}"#))
        #expect(
            NativeMathBound.accepts(
                #"\pick "# + String(repeating: "y", count: 3_000) + ";", definitions: #"\def\pick#1;{#1#1}"#))
        #expect(
            !NativeMathBound.accepts(
                #"\pick "# + String(repeating: "y", count: 4_100) + ";", definitions: #"\def\pick#1;{#1#1}"#))
    }

    @Test("引数の読み方によらない上界が実際の展開トークン数・バイト数・作業量を覆う")
    func countingProof() throws {
        for (declarations, formula) in [
            (#"\def\field#1{[#1]}\def\plane{\field{R}}\def\point{\plane^2}"#, #"\point+\plane"#),
            (#"\def\pair#1{{#1}+{#1}}"#, #"\pair{x+y}"#),
            (#"\def\pair#1{#1#1}"#, #"\pair{\pair{\pair{\pair{xy}}}}+\pair{z}"#),
            (#"\def\third#1{#1#1}\def\second#1{\third{#1#1}}\def\first#1{\second{#1#1}}"#, #"\first{xy}"#),
            (#"\def\prefix{\next}\def\next#1{#1z}"#, #"\prefix{x}+\prefix y"#),
        ] {
            let proof = try #require(NativeMathBound.bound(formula, definitions: declarations))
            var expander = PreviewMathExpansion()
            let output = try expander.expand(formula, definitions: declarations)
            let tokens = try PreviewMathExpansion.tokens(output)
            #expect(proof.bytes >= tokens.count && proof.bytes >= output.utf8.count)
            #expect(proof.work >= expander.scheduledBytes && proof.steps >= expander.steps)
            #expect(proof.bytes <= 8_192 && proof.work <= 65_536 && proof.steps < 1_000)
        }
    }

    @Test("空の置換も千回に達する前に拒み、単一引数の転送にも累計予算を適用する")
    func countsBeforeParsing() throws {
        let empty = #"\def\emptyop{}"#
        let calls = String(repeating: #"\emptyop"#, count: 999)
        #expect(try #require(NativeMathBound.bound(calls, definitions: empty)).steps == 999)
        #expect(NativeMathBound.bound(calls + #"\emptyop"#, definitions: empty) == nil)
        let nested =
            String(repeating: #"\passop{"#, count: 24) + String(repeating: "x", count: 3_000)
            + String(repeating: "}", count: 24)
        #expect(NativeMathBound.bound(nested, definitions: #"\def\passop#1{#1}"#) == nil)
        // The child-process inputs also have to fail here, before MathRenderer can construct a parser.
        let literal = String(repeating: "x", count: 2_049)
        #expect(AppMathInput.prepare(#"\pair{\pair{"# + literal + "}}", definitions: #"\def\pair#1{#1#1}"#) == nil)
        let chain = #"\def\leaf{"# + literal + #"}\def\pair{\leaf\leaf}\def\four{\pair\pair}"#
        #expect(AppMathInput.prepare(#"\four"#, definitions: chain) == nil)
    }

    @Test("実行中の代入・間接参照・条件分岐・再字句化・組み込み複写は構文解析前に拒む")
    func unseenExpansion() {
        for body in [
            #"{\def\another{x}}"#, #"\expandafter x"#, #"\iftrue x\else y\fi"#, #"\csname x\endcsname"#,
            #"\catcode"#, #"\let\alias=\word"#, #"\tmspace"#, #"\Braket"#, #"\Set"#, #"\set"#, #"\ce"#, #"\pu"#,
        ] {
            #expect(NativeMathBound.bound(#"\word"#, definitions: #"\def\word{"# + body + "}") == nil, "\(body)")
        }
        let declarations = #"\def\word{x}"#
        for helper in [#"\tmspace"#, #"\Braket"#, #"\Set"#, #"\set"#, #"\bra@ket"#, #"\bra@set"#, #"\ce"#, #"\pu"#] {
            #expect(AppMathInput.prepare(helper + #"{\word}"#, definitions: declarations) == nil)
        }
        for formula in [#"\word\def\word{y}"#, #"{\def\word{y}}\word"#, #"\TextOrMath{x}{\tmspace}\word"#] {
            #expect(AppMathInput.prepare(formula, definitions: declarations) == nil)
        }
    }

    @Test("数式の動的な名前を読む前に拒み、後続の利用者マクロと本文を表示する")
    func nameRefusalIsLocal() {
        let cycle = #"\def\loopword{\loopword}"#
        let name = #"\csname\loopword\endcsname"#
        let keep = #"\keepword{a+b}"#
        let md = "$$" + cycle + name + "$$\n\n" + #"$\def\keepword#1{#1}\keepword{a+b}$ Tail."#
        let tex =
            cycle + #"\NewDocumentCommand\keepword{m}{#1}\begin{document}$"# + name + "$ $" + keep
            + #"$ Tail.\end{document}"#
        for (html, original) in [
            (MarkdownConverter.convert(md).body, "$$" + cycle + name + "$$"),
            (LaTeXConverter.convert(tex).body, "$" + name + "$"),
        ] {
            #expect(html.contains("class=\"math-error\">" + HTML.escape(original)))
            #expect(html.components(separatedBy: "math-error").count == 2)
            #expect(html.components(separatedBy: "<svg ").count == 2)
            #expect(
                html.contains(">a</text>") && html.contains(">+</text>") && html.contains(">b</text>")
                    && html.contains("Tail."))
        }
        let document = LaTeXDocument(fontIndex: .init(faces: [:]))
        let reader = LaTeXReader(#"\loopword\endcsname"#, document: document, isBlock: false)
        let budget = ReaderMathBudget()
        reader.mathBudget = budget
        #expect(reader.readCSName().isEmpty && budget.refused && budget.steps == 0 && budget.scheduled == 0)
        #expect(!document.stopsExpanding && document.expansionWork == 0 && reader.index == 0)
    }

    @Test("拡張定義の置換を拒否しても次の式のマクロを使える")
    func extendedFormula() {
        let source = #"\NewDocumentCommand\copyword{m}{#1#1}\newcommand\unitword{x}"#
        let call = #"\copyword{"# + String(repeating: "x", count: 4_097) + "}"
        let html = LaTeXConverter.convert(source + "$" + call + #"$ 続き $\unitword$。"#).body
        #expect(html.contains("<code class=\"math-error\">$" + call + "$</code>"))
        #expect(html.contains("続き") && html.contains(">x</text>"))
    }

    @Test("利用者マクロの別名を拒み、使用しない定義の本文は展開しない")
    func capturedMeaning() throws {
        let definitions = #"\def\letterword{x}\let\savedword=\letterword \def\letterword{y}"#
        #expect(AppMathInput.prepare(#"\savedword+\letterword"#, definitions: definitions) == nil)
        // After '=', SwaTex's let skips exactly one space token. A comment can separate two.
        #expect(NativeMathBound.bound("x", definitions: "\\let\\savedword= % split\n \\letterword") == nil)
        let unused = #"\def\unused{\expandafter x}"#
        let ordinary = try #require(AppMathInput.prepare("a+b", definitions: unused))
        #expect(ordinary.input == unused + "a+b")
        let original = #"\def\word{x}% end of header"#
        let acrossComment = "\\unseen\n\\word"
        #expect(
            try #require(AppMathInput.prepare(acrossComment, definitions: original)).input == original + acrossComment)
        // The builtin argmin expands a thin space. An unavailable binding matters only to a
        // formula reaching that builtin, including an indirect call from a paper's wrapper.
        let tex =
            #"\def\,{z}\def\minimum{\argmin}\def\keepword#1{#1}\begin{document}$\minimum$ $\keepword{a+b}$ Tail.\end{document}"#
        let html = LaTeXConverter.convert(tex).body
        #expect(
            html.contains(#"class="math-error">$\minimum$"#) && html.contains(">b</text>") && html.contains("Tail."))
    }

    @Test("拡張マクロと無関係な長い数式の原文を保つ")
    func unrelatedLongMath() {
        let document = LaTeXDocument(fontIndex: .init(faces: [:]))
        document.hasExtendedMathDefinitions = true
        let reader = LaTeXReader("", document: document, isBlock: false)
        let formula = String(repeating: #"\alpha+"#, count: 1_500) + "x"
        #expect(reader.expandMathCommands(formula) == formula)
        #expect(!document.mathExpansionLimitReached)
    }

    @Test("拡張置換は累計予算に入りきらない引数を複写する前に拒む")
    func extendedWork() {
        let document = LaTeXDocument(fontIndex: .init(faces: [:]))
        let reader = LaTeXReader("{abc}", document: document, isBlock: false)
        let budget = ReaderMathBudget()
        budget.scheduled = 65_533
        reader.mathBudget = budget
        #expect(reader.replacement(.init(parameters: 1, defaultArgument: nil, body: "#1#1")) == nil)
        #expect(budget.refused && budget.scheduled == 65_533 && budget.steps == 0)
        #expect(reader.characters == Array("{abc}"))
    }

    @Test("Org は最後のヘッダー定義を文書全体の式に適用する")
    func orgRedefinition() {
        let text = """
            #+LATEX_HEADER: \\def\\wordmark{x}

            $\\wordmark$

            #+LATEX_HEADER: \\def\\wordmark{y}

            $\\wordmark$
            """
        let html = OrgConverter.convert(text).body
        #expect(html.components(separatedBy: ">y</text>").count == 3)
        #expect(!html.contains("math-error"))
        let grouped = OrgConverter.convert("#+LATEX_HEADER: {\\def\\vec{x}}\n\n$\\vec{y}$ $a+b$ Tail.").body
        #expect(grouped.contains("math-error") && grouped.contains(">b</text>") && grouped.contains("Tail."))
    }

    @Test("本文の置換は一文字に結合した複数のスカラーもバイトで計数する")
    func proseBytes() {
        let grapheme = "a" + String(repeating: "\u{0301}", count: 25_000)
        let document = LaTeXDocument(fontIndex: .init(faces: [:]))
        let reader = LaTeXReader("{" + grapheme + "}", document: document, isBlock: false)
        #expect(reader.replacement(.init(parameters: 1, defaultArgument: nil, body: "#1#1")) == nil)
        #expect(document.stopsExpanding)
        #expect(document.expandedCharacters == 0)
    }
}
