import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXVerticalAppendixTests {
    @Test(
        "縦組みのクラスは付録の英字を縦中横にして正立させる",
        arguments: ["tbook", "treport", "utbook", "ltjtbook", "[tate,book]{jlreq"])
    func verticalAppendixLetter(name: String) {
        let declaration = name.hasPrefix("[") ? name + "}" : "{\(name)}"
        let tex = "\\documentclass\(declaration)\\begin{document}\\tableofcontents\\appendix\\chapter{箱}\\end{document}"
        let body = LaTeXConverter.convert(tex).body
        let tcy = #"<span class="explicit-tcy">A</span>"#
        #expect(body.contains(#"id="sec-A"><span class="secnum">"#) && body.contains(tcy + "</span>箱</h2>"))
        #expect(body.contains(##"<a href="#sec-A"><span class="secnum">"##))
        #expect(body.components(separatedBy: tcy).count == 3, "見出しと目次の 2 か所")
    }

    @Test("縦組みの記事クラスは付録の節の英字を縦中横にする")
    func verticalAppendixSection() {
        let tex = #"\documentclass{tarticle}\begin{document}\appendix\section{箱}\end{document}"#
        let body = LaTeXConverter.convert(tex).body
        #expect(body.contains(#"<span class="secnum"><span class="explicit-tcy">A</span></span>箱"#))
    }

    @Test("横組みのクラスの付録の英字は縦中横にしない")
    func horizontalAppendixLetter() {
        let tex = #"\documentclass{jbook}\begin{document}\appendix\chapter{箱}\end{document}"#
        #expect(!LaTeXConverter.convert(tex).body.contains("explicit-tcy"))
    }

    @Test("縦組みの付録の番号に付く終止点は、縦中横の外に置いて見出しと目次の両方に残す")
    func verticalAppendixSuffix() {
        let tex = #"""
            \documentclass{tarticle}\usepackage[spanish]{babel}
            \begin{document}\tableofcontents\appendix\section{資料}\end{document}
            """#
        let body = LaTeXConverter.convert(tex).body
        let number = #"<span class="secnum"><span class="explicit-tcy">A</span>.</span>資料"#
        #expect(body.contains(#"<h2 id="sec-A">"# + number + "</h2>"))
        #expect(body.contains(##"<a href="#sec-A">"## + number + "</a>"))
    }

    @Test(
        "縦組みの付録は 2 字以上の記号も、見出しと目次で 1 つの縦中横の箱に入れる",
        arguments: [
            ("tbook", #"\setcounter{chapter}{26}\chapter{箱}"#, "AA"),
            ("tbook", #"\renewcommand{\thechapter}{AAAA}\chapter{箱}"#, "AAAA"),
            ("tarticle", #"\setcounter{section}{26}\section{箱}"#, "AA"),
        ])
    func verticalAppendixLongLetters(row: (String, String, String)) {
        let tex = "\\documentclass{\(row.0)}\\begin{document}\\tableofcontents\\appendix\(row.1)\\end{document}"
        let body = LaTeXConverter.convert(tex).body
        let tcy = #"<span class="explicit-tcy">"# + row.2 + "</span>"
        #expect(body.contains(tcy + "</span>箱</h2>"))
        #expect(body.contains(tcy + "</span>箱</a>"))
    }
}
