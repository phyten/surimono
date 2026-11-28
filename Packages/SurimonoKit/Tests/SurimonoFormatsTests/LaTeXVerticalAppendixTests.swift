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
}
