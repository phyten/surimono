import CryptoKit
import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXPictureTests {
    @Test("arrows.meta の読み込みと局所の矢尻指定を図に反映する")
    func metaArrowLibrary() {
        let pic = #"\begin{tikzpicture}\draw[->] (0,0)--(1,0);\end{tikzpicture}"#
        let preamble = #"\documentclass{article}\usetikzlibrary{positioning,arrows.meta}\begin{document}"#
        func tip(_ name: String) -> String { HTML.escape(#"">":"\#(name)""#) }
        #expect(!LaTeXConverter.convert(pic).body.contains(tip("To")))
        #expect(LaTeXConverter.convert(preamble + pic + #"\end{document}"#).body.contains(tip("To")))
        let explicit = pic.replacingOccurrences(of: "[->]", with: "[->,>=Stealth]")
        #expect(LaTeXConverter.convert(preamble + explicit + #"\end{document}"#).body.contains(tip("Stealth")))
    }

    @Test("式の優先順位・度数法・関数・変数を同じ算術で求める")
    func expressions() throws {
        for (expr, expected) in [
            ("-2^2", -4.0), ("2^-2", 0.25), ("2^3^2", 512), ("2*(x+1)", 8),
            (#"\x-0.5*x^2"#, -1.5), ("sqrt(abs(-16))", 4), ("exp(ln(e))/e", 1),
            ("log10(100)+mod(8,3)", 4), ("min(2,max(1,3))", 2), ("floor(pi)+ceil(.2)+round(2.5)", 7),
            ("sin(90)+cos(60)+tan(45)", 2.5),
        ] {
            #expect(abs(try PGFMath.evaluate(expr, x: 3) - expected) < 1e-9)
        }
        for expr in [
            "0/0", "sqrt(-1)", "2 3", "unknown(2)", "1e999", "x+1", "2^", #"\sin(0)"#, "min(2,1e308*1e308)",
            "tan(-270)",
        ] {
            #expect(throws: TikZError.self) { try PGFMath.evaluate(expr) }
        }
    }

    @Test("図の中で多変数の反復と条件を展開し、図の外の定義を保つ")
    func expansion() {
        let fragment = LaTeXConverter.convert(
            #"""
            \def\p{before}
            \begin{tikzpicture}
            \newcommand{\dotat}[2]{\fill (#1,#2) circle(2pt);}
            \foreach \i/\j in {0/1,1/2,2/3}{
              \ifdim\i pt>0pt
                \pgfmathsetmacro{\p}{\i^2}
                \dotat{\p}{\j}
              \fi
            }
            \foreach \k in {1,...,3} \node at (\k,0){\textbf{目盛り} \\ \texttt{\k}};
            \end{tikzpicture}\p
            """#)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains(#"<span class="tikz-block""#))
        #expect(fragment.body.components(separatedBy: "&quot;kind&quot;:&quot;path&quot;").count - 1 == 2)
        #expect(fragment.body.components(separatedBy: "<template>").count - 1 == 3)
        #expect(fragment.body.contains("<strong>目盛り</strong>"))
        #expect(fragment.body.contains("<code>3</code>"))
        #expect(fragment.body.contains("before</p>"))
    }

    @Test("図のラベルの数式は表示用テンプレートに解決し必要な書体を埋め込む")
    func mathFonts() {
        let fragment = LaTeXConverter.convert(#"\begin{tikzpicture}\node at (1,2){$x$};\end{tikzpicture}"#)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains(#"<template><span class="math math-inline"><svg"#))
        #expect(fragment.body.contains("@font-face"))
    }

    @Test("未対応の図は部分描画せず図番号と言語別の図名を示す")
    func fallback() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{article}\usepackage[french]{babel}\begin{document}
            \begin{tikzpicture}\draw (0,0)--(1,0);\end{tikzpicture}
            \begin{tikzpicture}\draw (0,0)--(1,0);\pic{bad};\end{tikzpicture}
            \end{document}
            """#)
        #expect(fragment.body.components(separatedBy: #"<span class="tikz-block""#).count - 1 == 1)
        #expect(fragment.readingIssues.contains { $0.contains("2") && $0.contains(#"\pic"#) })
        #expect(fragment.body.contains("data-source="))
        #expect(!fragment.body.contains("cannot draw"))
    }

    @Test("描ける図は外部化ファイルの許可を要求せず、未対応の図だけ代替画像を探す")
    func optionalFallbackLookup() {
        var probed: [String] = []
        let source = #"""
            \begin{tikzpicture}\draw (0,0)--(1,0);\end{tikzpicture}
            \begin{tikzpicture}\matrix {A};\end{tikzpicture}
            """#
        let fragment = LaTeXConverter.convert(
            source, documentURL: URL(fileURLWithPath: "/fixture/main.tex"),
            imageExists: {
                probed.append($0.lastPathComponent)
                return $0.lastPathComponent == "main-figure1.pdf"
            }, canProbePictureFallback: { _ in false })
        #expect(probed == ["main-figure1.pdf"])
        #expect(fragment.body.contains("<img"))
        #expect(fragment.readingIssues.contains { $0.contains("2") && $0.contains(#"\matrix"#) })
    }

    @Test("閉じていない図・不明な条件・未対応の改行幅は部分描画しない")
    func invalidInput() {
        let inputs = [
            #"\begin{tikzpicture}\draw (0,0)--(1,0);"#,
            #"\begin{tikzpicture}\ifdim\unknown>1pt\draw (0,0)--(1,0);\fi\end{tikzpicture}"#,
            #"\begin{tikzpicture}\node {A\\[5mm]B};\end{tikzpicture}"#,
            #"\begin{tikzpicture}\foreach \a in {a,...,z}{\node {\a};}\end{tikzpicture}"#,
        ]
        for source in inputs {
            let fragment = LaTeXConverter.convert(source)
            #expect(!fragment.body.contains(#"<span class="tikz-block""#))
            #expect(!fragment.readingIssues.isEmpty)
        }
    }

    @Test("独立した図も文中の図も段落に入り、字下げと中央揃えは段落に従う")
    func paragraphPictures() {
        let pic = #"\begin{tikzpicture}\draw (0,0)--(1,0);\end{tikzpicture}"#
        let html = LaTeXConverter.convert(
            "Before " + pic + " after.\n\n" + pic + "\n\n" + #"\begin{center}"# + pic + #"\end{center}"#
                + #" {\centering "# + pic + #"\par}"#
        ).body
        #expect(html.contains(#"<p>Before <span class="tikz-block""#))
        #expect(html.contains("</template></span> after.</p>") || html.contains("</span></span> after.</p>"))
        #expect(html.contains(#"<p><span class="tikz-block""#))
        #expect(html.contains("<div class=\"latex-center\">\n<p><span class=\"tikz-block\""))
        #expect(html.contains(#"style="text-align: center; text-indent: 0"><span class="tikz-block""#))
    }

    @Test("図の前後の番号付きキャプションを診断に使い、番号なしと枠外は通し番号を保つ")
    func captionNumbers() {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{report}\begin{document}\setcounter{chapter}{6}\chapter{Seven}
            \begin{figure}\begin{tikzpicture}\badA;\end{tikzpicture}\caption{After}\end{figure}
            \begin{figure}\caption{Before}\begin{tikzpicture}\badB;\end{tikzpicture}\end{figure}
            \begin{figure}\begin{tikzpicture}\badC;\end{tikzpicture}\caption*{Unnumbered}\end{figure}
            \begin{tikzpicture}\badD;\end{tikzpicture}
            \end{document}
            """#)
        let expected = [
            #"Figure 7.1 (TikZ) — \badA"#, #"Figure 7.2 (TikZ) — \badB"#,
            #"Figure 3 (TikZ) — \badC"#, #"Figure 4 (TikZ) — \badD"#,
        ]
        #expect(fragment.readingIssues == expected)
        for detail in expected { #expect(fragment.body.contains("data-issue=\"\(detail)\"")) }
    }

    @Test("LaTeX 以外の図の HTML 断片は従来とバイト単位で一致する")
    func existingDiagrams() {
        let bodies = [
            MarkdownConverter.convert("## A\n\n```dot\ndigraph {a -> b}\n```\n").body,
            OrgConverter.convert("* A\n#+begin_src mermaid\nflowchart LR\nA-->B\n#+end_src").body,
            DiagramConverter.convert("digraph {a -> b}", format: .graphviz).body,
            DiagramConverter.convert("@startuml\nA -> B\n@enduml", format: .plantuml).body,
        ]
        let hashes = bodies.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(
            hashes == [
                "7e988dfea588dc4c6e02f97a00e394a2ac1f8a346ef5254f66ecdd411e747d87",
                "11efadbbcf46d875b127ea988d71ed5f4d5b02769d7c41a0c859ce949c14e618",
                "c07bc2b7df5233a5cce106fcd704cc005b1f80f2f98b5c906a4f61eb38b3ecbe",
                "168581c11e0f276cdd09eae289baf84c2b4d0d1955dc5076aa19f640d32d04ea",
            ])
    }
}
