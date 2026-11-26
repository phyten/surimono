import Foundation
import SwaTex
import Testing

@testable import SurimonoFormats

struct AppMathDifferentialTests {
    private struct Paper {
        let name: String
        let definitions: String
        let formulas: [String]

        init(_ name: String, _ definitions: String, _ formulas: [String]) {
            self.name = name
            self.definitions = definitions
            self.formulas = formulas
        }
    }

    private static let tokenReaders = [
        Paper(
            "token capture", #"\def\wordpair{ab}\def\closeword{)}"#,
            [
                #"\boxed\wordpair"#, #"\boxed{\wordpair}"#, #"\text\wordpair"#, #"\frac\wordpair c"#,
                #"\dotsc\closeword"#, #"\char`\wordpair"#,
                #"\TextOrMath\wordpair{x}"#, #"\text{\TextOrMath\wordpair{x}}"#,
            ]),
        Paper("raw color model", #"\def\modelword{RGB}"#, [#"\textcolor[\modelword]{0,0,0}{x}"#]),
    ]

    private static let papers: [Paper] = [
        Paper(
            "number fields", #"\def\R{\mathbb{R}}\def\N{\mathbb{N}}\def\C{\mathbb{C}}"#,
            [
                #"x\in\R"#,
                #"n\in\N"#,
                #"z\in\C"#,
                #"\R^d\times\R^k"#,
                #"f:\C\to\R"#,
                #"\N\subset\R\subset\C"#,
                #"\R_{\ge0}"#,
                #"A\in\C^{m\times n}"#,
            ]),
        Paper(
            "one-argument norm", #"\newcommand{\pnorm}[1]{\left\lVert#1\right\rVert}"#,
            [
                #"\pnorm{x}"#,
                #"\pnorm{x-y}^2"#,
                #"\pnorm{Ax}_2"#,
                #"\pnorm{\nabla f}_\infty"#,
                #"\pnorm{x+y}\le\pnorm{x}+\pnorm{y}"#,
                #"\frac{x}{\pnorm{x}}"#,
                #"\pnorm{\frac{u}{v}}_1"#,
                #"\lim_{n\to\infty}\pnorm{x_n-x}"#,
            ]),
        Paper(
            "two-argument norm", #"\def\lp#1#2{\lVert#1\rVert_{#2}}"#,
            [
                #"\lp{x}{p}"#,
                #"\lp{v}{2}^2"#,
                #"\lp{A}{F}"#,
                #"\lp{u-v}{\infty}"#,
                #"\lp xy"#,
                #"\lp{x_i}{p_i}"#,
                #"\lp{f}{L^2}"#,
                #"\lp{x+y}1\le\lp{x}1+\lp{y}1"#,
            ]),
        Paper(
            "absolute value", #"\def\abs#1{\left\lvert#1\right\rvert}"#,
            [
                #"\abs{x}"#,
                #"\abs{z}^2"#,
                #"\abs{-a}=\abs{a}"#,
                #"\abs{x-y}<\delta"#,
                #"\sum_i\abs{a_i}"#,
                #"\abs{\frac{a}{b}}"#,
                #"\abs{\abs{x}-1}"#,
                #"\abs{\det A}"#,
            ]),
        Paper(
            "conditional expectation", #"\newcommand{\ExpUnder}[2]{\mathbb{E}_{#1}\left[#2\right]}"#,
            [
                #"\ExpUnder{P}{X}"#,
                #"\ExpUnder{Q}{Y^2}"#,
                #"\ExpUnder{\pi}{f(X)}"#,
                #"\ExpUnder{t}{X_{t+1}}"#,
                #"\ExpUnder{P}{X\mid Y}"#,
                #"\ExpUnder{X}{\ExpUnder{Y}{Z}}"#,
                #"\ExpUnder{i}{g_i}=\mu"#,
                #"\ExpUnder{}{\exp(tX)}"#,
            ]),
        Paper(
            "probability", #"\newcommand{\ProbOf}[2]{\mathbb{P}_{#1}\left(#2\right)}"#,
            [
                #"\ProbOf{P}{A}"#,
                #"\ProbOf{}{X>t}"#,
                #"\ProbOf{\theta}{X=x}"#,
                #"\ProbOf{n}{A_n}\to1"#,
                #"\ProbOf{}{A\cap B}"#,
                #"\ProbOf{t}{Y\mid X}"#,
                #"1-\ProbOf{}{A^c}"#,
                #"\log\ProbOf{Q}{D}"#,
            ]),
        Paper(
            "optimization", #"\DeclareMathOperator*{\argmin}{arg\,min}\DeclareMathOperator*{\argmax}{arg\,max}"#,
            [
                #"\argmin_{x} f(x)"#,
                #"\argmax_{\theta}L(\theta)"#,
                #"x^*=\argmin_{u\in K}J(u)"#,
                #"\argmax_i p_i"#,
                #"\argmin_{a,b}E(a,b)"#,
                #"\argmax_{s\in S}r_s"#,
                #"\argmin_x\max_y L(x,y)"#,
                #"\argmax_{\alpha\ge0}D(\alpha)"#,
            ]),
        Paper(
            "operators", #"\DeclareMathOperator{\rankop}{rank}\DeclareMathOperator{\traceop}{tr}"#,
            [
                #"\rankop A"#,
                #"\traceop(A)"#,
                #"\rankop(AB)\le\rankop A"#,
                #"\traceop(A+B)"#,
                #"\traceop(A^2)"#,
                #"\rankop A+\dim K=n"#,
                #"\traceop(AB)=\traceop(BA)"#,
                #"\rankop_{k}(M)"#,
            ]),
        Paper(
            "vector redefinition", #"\renewcommand{\vec}[1]{\mathbf{#1}}"#,
            [
                #"\vec{x}"#,
                #"\vec v"#,
                #"\vec{x}_i"#,
                #"\vec{e}_1+\vec{e}_2"#,
                #"\vec{u}^{T}\vec{v}"#,
                #"A\vec{x}=\vec b"#,
                #"\vec{p}(t)"#,
                #"\frac{\vec{r}}{r}"#,
            ]),
        Paper(
            "epsilon redefinition", #"\renewcommand{\epsilon}{\varepsilon}"#,
            [
                #"\epsilon>0"#,
                #"B_\epsilon(x)"#,
                #"\epsilon_n\to0"#,
                #"O(\epsilon^2)"#,
                #"\epsilon+\delta"#,
                #"\epsilon_{ijk}"#,
                #"\lim_{\epsilon\to0}f_\epsilon"#,
                #"0<\epsilon<1"#,
            ]),
        Paper(
            "matrix shortcuts", #"\def\mat#1{\mathbf{#1}}\def\trans{^{\mathsf T}}"#,
            [
                #"\mat A\trans"#,
                #"\mat{X}\trans\mat{X}"#,
                #"\mat I_n"#,
                #"\det\mat M"#,
                #"\mat A_{ij}"#,
                #"\mat{U}\mat{\Sigma}\mat{V}\trans"#,
                #"\mat{K}^{-1}"#,
                #"\mat{A}+\lambda\mat I"#,
            ]),
        Paper(
            "differentials", #"\newcommand{\dd}{\,\mathrm{d}}"#,
            [
                #"\int f(x)\dd x"#,
                #"\dd t/\dd s"#,
                #"\int_0^1x^2\dd x"#,
                #"\oint_C A\dd l"#,
                #"\int p(z)\dd z=1"#,
                #"\frac{\dd y}{\dd t}"#,
                #"\iint f\dd x\dd y"#,
                #"\dd\mu(x)"#,
            ]),
        Paper(
            "Dirac notation", #"\def\ket#1{\left\lvert#1\right\rangle}\def\bra#1{\left\langle#1\right\rvert}"#,
            [
                #"\ket{\psi}"#,
                #"\bra{0}"#,
                #"\ket{0}\bra{1}"#,
                #"\bra{\phi}A\ket{\psi}"#,
                #"\ket{+}+\ket{-}"#,
                #"\ket{n}_A"#,
                #"\bra{j}\ket{k}"#,
                #"\sum_n\ket n\bra n"#,
            ]),
        Paper(
            "tensor indices", #"\def\tensor#1#2#3{{#1}^{#2}_{#3}}"#,
            [
                #"\tensor T i j"#,
                #"\tensor R{\mu}{\nu}"#,
                #"\tensor g{ij}{}"#,
                #"\tensor F{}{ab}"#,
                #"\tensor T i j\tensor v j{}"#,
                #"\tensor{\Gamma}{k}{ij}"#,
                #"\nabla_k\tensor A i j"#,
                #"\tensor{\delta} i i=n"#,
            ]),
        Paper(
            "three levels", #"\def\field#1{\mathbb{#1}}\def\scalars{\field{R}}\def\spaceof#1{\scalars^{#1}}"#,
            [
                #"x\in\spaceof d"#,
                #"\spaceof{m+n}"#,
                #"T:\spaceof m\to\spaceof n"#,
                #"\spaceof{2k}\times\scalars"#,
                #"\spaceof0"#,
                #"\spaceof{\dim V}"#,
                #"\spaceof k\subseteq\spaceof n"#,
                #"\spaceof{n-1}\times\scalars"#,
            ]),
        Paper(
            "token boundaries", #"\def\joinvar#1{#1x}\def\greek{\alpha}\def\pairvar#1#2{#1#2}"#,
            [
                #"\joinvar a"#,
                #"\joinvar{\beta}"#,
                #"\joinvar\greek"#,
                #"\pairvar{\alpha}{b}"#,
                #"\pairvar{\greek}{xy}"#,
                #"\joinvar{a+b}"#,
                #"\pairvar{\beta}{\gamma}z"#,
                #"\joinvar{{x+y}}^2"#,
            ]),
        Paper(
            "text and spaces", #"\def\method{finite element}\def\labelword#1{\text{#1}}"#,
            [
                #"\text{\method}"#,
                #"u_{\text{\method}}"#,
                #"\labelword{strong form}"#,
                #"\text{a \method{} method}"#,
                #"\labelword{weak \method}"#,
                #"\labelword{A and B}"#,
                #"x_{\labelword{at rest}}"#,
                #"\text{\method{} basis}"#,
            ]),
        Paper(
            "comments",
            #"""
            \def\inner#1#2{% first argument
            \langle #1,% separator
            #2\rangle}

            """#,
            [
                #"\inner uv"#,
                #"\inner{u}{v+w}"#,
                #"\inner{\alpha}{x}"#,
                #"\inner xx\ge0"#,
                #"\inner{Ax}{y}"#,
                #"\inner{x_i}{e_j}"#,
                #"\inner{a+b}{c+d}"#,
                #"|\inner{f}{g}|"#,
            ]),
        Paper(
            "alignment tokens", #"\def\cellsep{&}\def\rowend{\\}"#,
            [
                #"\begin{matrix}a\cellsep b\rowend c\cellsep d\end{matrix}"#,
                #"\begin{pmatrix}1\cellsep0\rowend0\cellsep1\end{pmatrix}"#,
                #"\begin{bmatrix}x\rowend y\end{bmatrix}"#,
                #"\begin{aligned}a\cellsep=b\rowend c\cellsep=d\end{aligned}"#,
                #"\begin{matrix}0\cellsep I\end{matrix}"#,
                #"\begin{pmatrix}u\rowend v\rowend w\end{pmatrix}"#,
                #"\begin{aligned}f(x)\cellsep=x^2\end{aligned}"#,
                #"\begin{bmatrix}\alpha\cellsep\beta\end{bmatrix}"#,
            ]),
        Paper(
            "environments",
            ##"\def\colvec#1#2{\begin{pmatrix}#1\\#2\end{pmatrix}}\def\diagmat#1#2{\begin{bmatrix}#1&0\\0&#2\end{bmatrix}}"##,
            [
                #"\colvec{x}{y}"#,
                #"\diagmat{a}{b}"#,
                #"\colvec{u+v}{w}"#,
                #"A\colvec{x_1}{x_2}"#,
                #"\diagmat{1}{-1}^2"#,
                #"\colvec{\alpha}{\beta}"#,
                #"\diagmat{\lambda_1}{\lambda_2}"#,
                #"\colvec0{1}"#,
            ]),
        Paper(
            "split delimiters", #"\def\openangle{\left\langle}\def\closeangle{\right\rangle}"#,
            [
                #"\openangle x\closeangle"#,
                #"\openangle x,y\closeangle"#,
                #"\openangle\frac ab,c\closeangle"#,
                #"\openangle Ax,x\closeangle\ge0"#,
                #"\openangle e_i,e_j\closeangle"#,
                #"\openangle\openangle x\closeangle\closeangle"#,
                #"\openangle v,w\closeangle^2"#,
                #"\openangle f,g\closeangle_H"#,
            ]),
        Paper(
            "grouping", #"\def\square#1{{#1}^2}\def\bare#1{#1}"#,
            [
                #"\square x"#,
                #"\square{x+y}"#,
                #"\bare{x+y}^2"#,
                #"\bare{{x+y}}^2"#,
                #"\square{\frac xy}"#,
                #"\square{\bare x}"#,
                #"\sqrt{\bare{a+b}}"#,
                #"\bare{\square{x_i}}"#,
            ]),
        Paper(
            "provided notation", #"\providecommand{\indicator}[1]{\mathbf{1}_{#1}}"#,
            [
                #"\indicator A"#,
                #"\indicator{X>0}"#,
                #"\sum_i\indicator{A_i}"#,
                #"\indicator{\{x\}}"#,
                #"\indicator{A\cap B}"#,
                #"\indicator{A^c}=1-\indicator A"#,
                #"\indicator{[0,1]}(x)"#,
                #"\int\indicator E"#,
            ]),
        Paper(
            "math wrapper", #"\providecommand{\ensuremath}[1]{#1}\newcommand{\diffop}{\ensuremath{\partial}}"#,
            [
                #"\diffop_t u"#,
                #"\ensuremath{\nabla} f"#,
                #"\diffop_x^2 v"#,
                #"\frac{\diffop f}{\diffop y}"#,
                #"\ensuremath{x+y}"#,
                #"\diffop_\mu J^\mu"#,
                #"\diffop_{ij}f"#,
                #"\diffop_t+\diffop_s"#,
            ]),
        Paper(
            "primitive delimited arguments", #"\def\coord#1;{(#1)}"#,
            [
                #"\coord x;"#,
                #"\coord x+y;"#,
                #"\coord a,b;"#,
                #"\coord x_i;"#,
                #"\coord (t+1);"#,
                #"\coord u;^2"#,
                #"v=\coord x,y,z;"#,
                #"\coord {a+b};"#,
            ]),
        Paper(
            "redefined user command", #"\newcommand{\lossfn}{L}\renewcommand{\lossfn}{\mathcal L}"#,
            [
                #"\lossfn(x)"#,
                #"\lossfn_\theta"#,
                #"\nabla\lossfn"#,
                #"\lossfn(x,y)"#,
                #"\lossfn^*"#,
                #"\lossfn_{\rm test}"#,
                #"\min_x\lossfn(x)"#,
                #"\lossfn_1+\lossfn_2"#,
            ]),
        Paper(
            "space tokens after substitution", #"\def\captionword#1{#1 result}\def\glueword#1#2{#1#2}"#,
            [
                #"\text{\captionword{\S}}"#, #"\text{\captionword{\P}}"#,
                #"\text{\glueword{first }{ stage}}"#, #"\text{\glueword{a }{ b}}"#,
                #"\captionword{\alpha}"#, #"\text{\captionword{main}}"#,
            ]),
        Paper(
            "subsequent provide", #"\def\law{Q}\providecommand{\law}{P}"#,
            [
                #"\law(X)"#, #"X\sim\law"#,
            ]),
        Paper(
            "provided standard notation", #"\providecommand{\epsilon}{\varepsilon}"#,
            [
                #"\epsilon\to0"#, #"a_\epsilon(t)"#,
            ]),
        Paper(
            "default subscript", #"\newcommand{\expect}[2][P]{\mathbb E_{#1}[#2]}"#,
            [
                #"\expect{X}"#,
                #"\expect[Q]{X^2}"#,
            ]),
        Paper(
            "starred command", #"\newcommand*{\density}[1]{p(#1)}"#,
            [
                #"\density{x}"#
            ]),
        Paper(
            "starred renewal", #"\renewcommand*{\vec}[1]{\mathbf{#1}}"#,
            [
                #"\vec{v}"#
            ]),
        Paper(
            "unbraced primitive", #"\def\unitdx x"#,
            [
                #"\unitdx"#
            ]),
    ]

    @Test("論文の定義を使った各数式は旧経路と同じバイト列の数式画像になる")
    func comparesNativeAndApp() {
        var native = 0
        var fallback: Set<String> = []
        var seen: Set<String> = []
        let oldParserFailures: Set<String> = [
            // 0.6.0 takes "[" as the body and expects a second mandatory argument.
            #"default subscript: \expect{X}"#,
            // The raw parser reads "*" as the new command's name, which is already defined.
            #"starred command: \density{x}"#,
            // A primitive definition only starts its replacement at an opening brace.
            #"unbraced primitive: \unitdx"#,
        ]
        for paper in Self.papers + Self.tokenReaders {
            for formula in paper.formulas {
                let id = "\(paper.name): \(formula)"
                #expect(seen.insert(id).inserted)
                let prepared = AppMathInput.prepare(formula, definitions: paper.definitions)
                // The raw default has a bounded expansion but still lacks a mandatory argument
                // in SwaTex. The other two parser errors have no accepted declaration signature.
                if !oldParserFailures.contains(id) || id == #"default subscript: \expect{X}"# {
                    #expect(prepared?.route == .boundedNative, "\(id)")
                    #expect(prepared?.input.utf8.elementsEqual((paper.definitions + formula).utf8) == true, "\(id)")
                    if prepared?.route == .boundedNative { native += 1 }
                } else {
                    #expect(prepared == nil, "\(id)")
                }
                if oldParserFailures.contains(id) {
                    #expect(throws: ParseError.self) { try parseLaTeX(paper.definitions + formula) }
                }
                // Inline and display share one route but have independent SVGs (spacing and limits).
                for display in [false, true] {
                    let actual = MathRenderer.html(formula, display: display, macros: paper.definitions)
                    let expected = legacyHTML(formula, definitions: paper.definitions, display: display)
                    if oldParserFailures.contains(id) {
                        #expect(expected == nil && actual == nil, "\(id), display=\(display)")
                        fallback.insert(id)
                    } else if let expected, let actual {
                        #expect(expected.utf8.elementsEqual(actual.utf8), "\(id), display=\(display)")
                    } else {
                        Issue.record("\(id), display=\(display), native=\(expected != nil), app=\(actual != nil)")
                    }
                }
            }
        }
        #expect(fallback == oldParserFailures)
        #expect(native == 230 && seen.count == 232)
    }

    @Test("先読みや生の引数を持つ数式は Finder で同じ画像または原文になる")
    func previewTokenReaders() throws {
        let afterArgument = #"\boxed{a}+\wordpair"#
        let boundaries = Paper(
            "end of argument", #"\def\wordpair{ab}"#, [afterArgument, #"\TextOrMath{\boxed}{\boxed}\wordpair"#])
        func inPreview(_ render: () -> String?) -> String? {
            PreviewConversion.$current.withValue(PreviewConversion(deadline: .now + .seconds(5)), operation: render)
        }
        for paper in Self.tokenReaders + [boundaries] {
            for formula in paper.formulas {
                for display in [false, true] {
                    let reference = inPreview { legacyHTML(formula, definitions: paper.definitions, display: display) }
                    let expected = try #require(reference)
                    let preview = inPreview { MathRenderer.html(formula, display: display, macros: paper.definitions) }
                    if let preview {
                        #expect(preview.utf8.elementsEqual(expected.utf8), "\(formula)")
                    } else {
                        #expect(formula != afterArgument, "The boxed argument already ended")
                    }
                }
            }
        }
    }

    @Test("生の既定引数や星付き定義は複写量と後続の命令を検査できる場合だけ元のまま組む")
    func rawSignatureBound() {
        let defaults = #"\newcommand{\aver}[2][P]{#1+#2}"#
        let call = #"\aver[Q]{x}"#
        #expect(NativeMathBound.accepts(call, definitions: defaults))
        let atLimit =
            call
            + String(repeating: "x", count: PreviewMathExpansion.maximumBytes - defaults.utf8.count - call.utf8.count)
        #expect(!NativeMathBound.accepts(atLimit, definitions: defaults))
        #expect(!NativeMathBound.accepts(call, definitions: defaults + #"\def\other{x}"#))
        let starred = #"\renewcommand*{\vec}[1]{\mathbf{#1}}"#
        #expect(NativeMathBound.accepts(#"\vec{x}"#, definitions: starred))
        #expect(!NativeMathBound.accepts(#"\vec{x}*v"#, definitions: starred))
    }

    // Same parsed-node renderer, independent parser input. Only fixed, hand-written test strings
    // reach this reference; document content always goes through AppMathInput.
    private func legacyHTML(_ formula: String, definitions: String, display: Bool, original: String? = nil) -> String? {
        guard let parsed = try? parseLaTeX(definitions + formula) else { return nil }
        return MathRenderer.renderParsed(parsed, source: formula, original: original ?? formula, display: display)
    }

    @Test("LaTeX 本文の既定引数と星付き定義は旧リーダーが渡していた式と同じ数式画像になる")
    func latexReaderSignatures() throws {
        // The previous LaTeX reader expanded defaults before parsing and lowered starred commands
        // to primitive definitions. Keep its parser inputs explicit, independent of today's reader.
        let paper = #"""
            \newcommand{\Eop}{\mathbb{E}}
            \newcommand{\expect}[2][P]{\Eop_{#1}[#2]}
            \newcommand{\prob}[2][\theta]{\Eop_{#1}(#2)}
            \newcommand*{\density}[1]{p(#1)}
            \renewcommand*{\vec}[1]{\mathbf{#1}}
            """#
        let legacyDefinitions = #"\def\Eop{\mathbb{E}}\def\density#1{p(#1)}\def\vec#1{\mathbf{#1}}"#
        let formulas = [
            (#"\expect{X}"#, #"\Eop_{P}[X]"#),
            (#"\expect[Q]{X^2}"#, #"\Eop_{Q}[X^2]"#),
            (#"\expect[\pi]{f(X)}"#, #"\Eop_{\pi}[f(X)]"#),
            (#"\expect{X\mid Y}"#, #"\Eop_{P}[X\mid Y]"#),
            (#"\prob{A}"#, #"\Eop_{\theta}(A)"#),
            (#"\prob[t]{A_t}"#, #"\Eop_{t}(A_t)"#),
            (#"\density{x}"#, #"\density{x}"#),
            (#"\vec{v}"#, #"\vec{v}"#),
            (#"\expect{\density{x}}"#, #"\Eop_{P}[\density{x}]"#),
            (#"\prob[Q]{\vec{v}>0}"#, #"\Eop_{Q}(\vec{v}>0)"#),
        ]
        for (original, normalized) in formulas {
            let expected = try #require(
                legacyHTML(normalized, definitions: legacyDefinitions, display: false, original: original))
            let html = LaTeXConverter.convert(paper + "\n" + #"\begin{document}$"# + original + #"$\end{document}"#)
                .body
            #expect(html.utf8.firstRange(of: expected.utf8) != nil, "\(original)")
            #expect(AppMathInput.prepare(normalized, definitions: legacyDefinitions)?.route == .boundedNative)
        }
    }
}
