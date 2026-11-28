import Foundation
import SwaTex
import Testing

@testable import SurimonoFormats

struct NativeMathSymbolTests {
    private let header = #"\newcommand{\foo}{x}"#

    @Test("前置きに定義があっても \\ldots・\\cdots・\\ne・\\neq・\\dots を含む式を組む")
    func commonSymbolsAfterDefinition() throws {
        let formulas = [
            #"x\ne y"#, #"x\neq y"#, #"a_1,\ldots,a_n"#, #"1+\cdots+n"#, #"a_1\dots a_n"#,
            #"a\dotsb b\dotsm c\dotso d\dotsx e"#, #"x\not\in A"#,
        ]
        for formula in formulas {
            #expect(AppMathInput.prepare(formula, definitions: header)?.route == .boundedNative, "\(formula)")
        }
        let body = formulas.map { "$" + $0 + "$" }.joined(separator: " ")
        let html = LaTeXConverter.convert(
            #"\documentclass{article}"# + header + #"\begin{document}"# + body + #"\end{document}"#
        ).body
        #expect(!html.contains("math-error"))
        #expect(html.components(separatedBy: "<svg ").count == formulas.count + 1)
    }

    @Test("展開のない記号は、利用者の定義がある文書でも受け付ける")
    func everyUnexpandedSymbol() throws {
        // SwaTex has no public list of its symbol table. Every codepoint-bearing entry is reachable
        // through the codepoint index, which returns the first name registered for that character.
        var names: Set<String> = []
        for value in 0...0x1_FFFF {
            guard let scalar = Unicode.Scalar(value), let info = SymbolInfo(codepoint: scalar, mode: .math) else {
                continue
            }
            names.insert(info.name)
        }
        // Names without a codepoint, and aliases of an earlier entry.
        names.formUnion([#"\nobreak"#, #"\le"#, #"\ge"#, #"\to"#, #"\gets"#, #"\lbrace"#, #"\rbrace"#, #"\hbar"#])
        var checked = 0
        for name in names.sorted() where name.hasPrefix("\\") && name.dropFirst().allSatisfy(\.isLetter) {
            guard SymbolInfo(name: name, mode: .math) != nil else { continue }
            // Decide "no expansion" from the parser itself, independently of the bound's own test.
            let parser = Parser(name)
            guard let nodes = try? parser.parse(), nodes.count == 1, nodes[0].isSymbolNode else { continue }
            let expansions = try #require(Mirror(reflecting: parser).descendant("gullet", "expansionCount") as? Int)
            guard expansions == 0 else { continue }
            checked += 1
            #expect(NativeMathBound.accepts("a" + name + "+b", definitions: header), "\(name)")
            #expect(AppMathInput.prepare(name, definitions: header)?.route == .boundedNative, "\(name)")
        }
        #expect(checked > 300)
    }

    @Test("展開のある点と否定の記号は固定版 SwaTex の実展開回数を上界が覆う")
    func expandingSymbolsAreCosted() throws {
        for formula in [
            #"\dots"#, #"\cdots"#, #"\dotsb"#, #"\dotsm"#, #"\dotso"#, #"\dotsx"#, #"\ne"#, #"\neq"#,
            #"\not="#,
        ] {
            let bound = try #require(NativeMathBound.bound("a" + formula + "+b", definitions: header), "\(formula)")
            let parser = Parser(header + "a" + formula + "+b")
            #expect(!(try parser.parse()).isEmpty)
            let count = try #require(Mirror(reflecting: parser).descendant("gullet", "expansionCount") as? Int)
            // The header's own newcommand is one expansion; it is charged as an assignment.
            #expect(count <= bound.steps, "\(formula)")
        }
    }

    @Test("記号を多く並べた式も上限の中で組み、上限を超える長さは今までどおり拒む")
    func symbolsStayInsideLimits() {
        let row = String(repeating: #"a\ne b,\ldots,"#, count: 6)
        #expect(NativeMathBound.accepts(row, definitions: header))
        let leaves = String(repeating: #"\ldots"#, count: 1_400)
        #expect(!NativeMathBound.accepts(leaves, definitions: header))
        let costed = String(repeating: #"\ne"#, count: 40)
        #expect(!NativeMathBound.accepts(costed, definitions: header))
    }

    @Test("組み込みの記号を定義し直す前置きは拒み、論文の慣用の名前だけを受け付ける")
    func redefiningSymbols() {
        for name in [#"\ldots"#, #"\hbar"#, #"\cdots"#, #"\ne"#, #"\nobreak"#] {
            #expect(!NativeMathBound.mayDeclare(name), "\(name)")
            #expect(!NativeMathBound.accepts("x", definitions: #"\renewcommand{"# + name + "}{y}"), "\(name)")
            #expect(!NativeMathBound.accepts("x", definitions: #"\def"# + name + "{y}"), "\(name)")
        }
        // Listing a costed symbol's helpers must not take a paper's own thin space or square away.
        for name in [#"\square"#, #"\epsilon"#, #"\!"#] { #expect(NativeMathBound.mayDeclare(name), "\(name)") }
        #expect(NativeMathBound.accepts(#"\square x"#, definitions: #"\def\square#1{{#1}^2}"#))
        #expect(NativeMathBound.accepts(#"\epsilon"#, definitions: #"\providecommand{\epsilon}{\varepsilon}"#))
        // A document that changed a helper hidden inside a costed symbol cannot draw that symbol.
        let tex = #"\def\cdots{X}\begin{document}$a\dots b$ $a\ldots b$\end{document}"#
        let html = LaTeXConverter.convert(tex).body
        #expect(html.contains(#"class="math-error">$a\dots b$"#))
        #expect(!html.contains(#"class="math-error">$a\ldots b$"#))
    }
}
