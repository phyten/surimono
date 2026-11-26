import Foundation
import Testing

@testable import SurimonoFormats

struct AppMathInputTests {
    @Test("展開結果が枠に収まらない引数のコピーを積む前に拒む")
    func byteCounters() {
        var expansion = PreviewMathExpansion()
        let call = #"\copyword{"# + String(repeating: "x", count: 4_097) + "}"
        #expect(throws: PreviewMathExpansion.Refusal.size) {
            try expansion.expand(call, definitions: #"\def\copyword#1{#1#1}"#, app: true)
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
            !NativeMathBound.accepts(
                #"\pick "# + String(repeating: "y", count: 3_000) + ";", definitions: #"\def\pick#1;{#1#1}"#))
    }

    @Test("拡張定義の置換を拒否しても次の式のマクロを使える")
    func extendedFormula() {
        let source = #"\NewDocumentCommand\copyword{m}{#1#1}\newcommand\unitword{x}"#
        let call = #"\copyword{"# + String(repeating: "x", count: 4_097) + "}"
        let html = LaTeXConverter.convert(source + "$" + call + #"$ 続き $\unitword$。"#).body
        #expect(html.contains("<code class=\"math-error\">$" + call + "$</code>"))
        #expect(html.contains("続き") && html.contains(">x</text>"))
    }

    @Test("let は保存した定義を展開し、無関係な定義は次の式に持ち込まない")
    func capturedMeaning() throws {
        let definitions = #"\def\letterword{x}\let\savedword=\letterword \def\letterword{y}"#
        let captured = try #require(AppMathInput.prepare(#"\savedword+\letterword"#, definitions: definitions))
        #expect(captured.input == "x+y")
        #expect(captured.route == .expanded)
        let ordinary = try #require(AppMathInput.prepare("a+b", definitions: #"\def\unused{\expandafter x}"#))
        #expect(ordinary.route == .original && ordinary.input == "a+b")
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
