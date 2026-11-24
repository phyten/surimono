import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXCompositionTests {
    @Test("登録された全クラスのうち、標準の原稿クラスだけで組み方を選べる")
    func eligibleClasses() {
        let eligible = Set(
            """
            article report book jsarticle jsreport jsbook ltjsarticle ltjsreport ltjsbook bxjsarticle bxjsreport bxjsbook
            jarticle jreport jbook ltjarticle ltjreport ltjbook ujarticle ujreport ujbook utarticle utreport utbook
            tarticle treport tbook ltjtarticle ltjtreport ltjtbook jlreq ctexart ctexrep ctexbook oblivoir scrartcl scrreprt scrbook memoir
            """.split(whereSeparator: \.isWhitespace).map(String.init))
        #expect(eligible.isSubset(of: Set(LaTeXClassRegistry.registeredNames)))
        for name in LaTeXClassRegistry.registeredNames + ["custom"] {
            let source = #"\documentclass{\#(name)}\begin{document}Text.\end{document}"#
            #expect(
                LaTeXConverter.convert(source).latexClass?.offersCompositionChoice == eligible.contains(name), "\(name)"
            )
        }
    }

    @Test("学会スタイルと原稿内の段組指定を優先し、コメントや未使用のマクロは無視する")
    func sourceControls() throws {
        for source in [
            #"\documentclass[twocolumn]{article}\begin{document}Body."#,
            #"\documentclass{article}\usepackage{iclr2027_conference}\begin{document}Body."#,
            #"\documentclass{article}\usepackage{neurips_2026}\begin{document}Body."#,
            #"\documentclass{article}\begin{document}\twocolumn Body.\onecolumn End."#,
            #"\documentclass{article}\begin{document}\begin{multicols}{2}Body.\end{multicols}"#,
        ] {
            let normal = LaTeXConverter.convert(source)
            #expect(normal.latexClass?.offersCompositionChoice == false)
            for choice in [LaTeXComposition.twoColumn, .proof] {
                #expect(LaTeXConverter.convert(source, composition: choice) == normal)
            }
        }
        let quoted = #"""
            \documentclass{article}
            % \usepackage{neurips_2026}
            \newcommand{\unused}{\twocolumn}
            \begin{document}\verb|\twocolumn|\end{document}
            """#
        #expect(LaTeXConverter.convert(quoted).latexClass?.offersCompositionChoice == true)
    }

    @Test("校正では左端と天地を保って右に40mmを空け、本文の行送りだけを広げる")
    func proofGeometry() throws {
        let source = #"\documentclass[twoside]{book}\begin{document}Body.\end{document}"#
        let normal = LaTeXConverter.convert(source)
        #expect(LaTeXConverter.convert(source, composition: .document) == normal)
        let before = try #require(normal.latexClass).pageBox
        let proof = try #require(LaTeXConverter.convert(source, composition: .proof).latexClass)
        let after = proof.pageBox
        #expect(proof.composition == .proof && proof.columns == 1)
        #expect(before.left == after.left && before.evenLeft == after.evenLeft)
        #expect(before.top == after.top && before.bottom == after.bottom)
        #expect(abs(after.right - before.right - 40 * 72.0 / 25.4) < 0.0001)
        #expect(proof.styleVariables.contains("--latex-stretch: 1.5"))
        #expect(proof.styleVariables.contains("--latex-float-stretch: 1"))
    }
}
