import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXVerticalTests {
    @Test("同じ jlreq でも縦横のクラス情報は区別し、章のない原稿では開始面の指定だけを保持する")
    func chapterlessClass() {
        let vertical = LaTeXDocumentClassInfo(name: "jlreq", options: " uplatex, tate , openany, openright ")
        let horizontal = LaTeXDocumentClassInfo(name: "jlreq", options: "uplatex")
        #expect(vertical.isVertical)
        #expect(!horizontal.isVertical)
        #expect(vertical != horizontal)
        #expect(vertical.profile.structure.declaredOpening == .right)
        #expect(vertical.profile.bookOpeningSide == nil)
    }

    @Test("縦組みの章と無番号章には改ページ標識が付き、節には付かない", arguments: ["tbook", "treport", "jlreq"])
    func chapterBoundaries(name: String) {
        let body = LaTeXConverter.convert(
            #"\documentclass[tate,report,openany]{\#(name)}\begin{document}\chapter{春}\section{梅}本文\chapter*{秋}\end{document}"#
        ).body
        let chapters = body.matches(of: /<template data-latex-break="[^"]+"><\/template>\s*<h2[^>]* id="sec-[^"]+">/)
        #expect(chapters.count == 2)
        #expect(body.contains(#"<span class="secnum">1.1</span>梅"#))
    }

    @Test("局所的な組み方向・割注・字取りでは引数の文字を残す")
    func localCommands() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass[uplatex]{jlreq}\begin{document}{\yoko 横}{\tate 縦}\warichu{割注}\jidori{字取り}\end{document}"#)
        #expect(fragment.body.contains("横縦割注字取り"))
        #expect(fragment.latexClass?.isVertical == false)
    }

    @Test("縦組みの文書でも用紙・段数・両面・章の開始面を読み取る")
    func classOptions() throws {
        let info = LaTeXConverter.documentClassInfo(
            #"\documentclass[tate,book,b5paper,twocolumn,twoside,openright]{jlreq}"#)
        let paper = try #require(info.declaredPaperSize)
        #expect(abs(paper.width - 182 * 72 / 25.4) < 0.01)
        #expect(abs(paper.height - 257 * 72 / 25.4) < 0.01)
        #expect(info.columns == 2)
        #expect(info.pageBox.mirrorsSides)
        #expect(info.profile.bookOpeningSide == "right")

        let single = LaTeXConverter.documentClassInfo(#"\documentclass[a5paper,onecolumn,oneside,openany]{ltjtbook}"#)
        #expect(single.columns == 1)
        #expect(!single.pageBox.mirrorsSides)
        #expect(single.profile.bookOpeningSide == "page")
        let small = try #require(single.declaredPaperSize)
        #expect(abs(small.width - 148 * 72 / 25.4) < 0.01)
    }

    @Test("縦中横は書式や入れ子を取り除いた文字だけを含み、数式とは独立する", arguments: ["tarticle", "article"])
    func inlineNumbers(name: String) {
        let body = LaTeXConverter.convert(
            #"\documentclass{\#(name)}\begin{document}\tatechuyoko{12}\rensuji[ignored]{\textbf{3}\rensuji{4}}\rensuji{<\&>}$56$\end{document}"#
        ).body
        #expect(
            body.contains(
                #"<span class="tcy">12</span><span class="tcy">34</span><span class="tcy">&lt;&amp;&gt;</span>"#))
        #expect(body.components(separatedBy: #"class="tcy""#).count == 4)
        #expect(body.contains("<svg"))
    }

    @Test("縦中横の前方参照はリンクを入れずに解決後の番号を残す")
    func combinedReference() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{article}\usepackage{hyperref}\begin{document}\rensuji{\ref{later}}\section{節}\label{later}\end{document}"#
        )
        #expect(fragment.body.contains(#"<span class="tcy">1</span>"#))
    }

    @Test("縦横どちらでもルビの読みをまとめ、傍点と傍線を区別する", arguments: ["tarticle", "article"])
    func annotations(name: String) {
        let body = LaTeXConverter.convert(
            #"\documentclass{\#(name)}\begin{document}\ruby{山}{やま}\jruby[g]{青空}{あお|ぞら}\ruby[m]{海}{うみ}\kenten{点}\bou{線}\end{document}"#
        ).body
        #expect(body.contains("<ruby>山<rt>やま</rt></ruby><ruby>青空<rt>あおぞら</rt></ruby><ruby>海<rt>うみ</rt></ruby>"))
        #expect(body.contains(#"<span class="kenten">点</span><span class="bousen">線</span>"#))
    }
}
