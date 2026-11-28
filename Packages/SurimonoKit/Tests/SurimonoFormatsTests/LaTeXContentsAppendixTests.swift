import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXContentsAppendixTests {
    @Test(
        "横書きの書籍クラスの目次は付録の章を「付録」の名前で載せる",
        arguments: [
            ("jbook", "付 録"), ("ltjbook", "付 録"), ("ujbook", "付 録"), ("jreport", "付 録"),
            ("jsbook", "付録"), ("ltjsbook", "付録"), ("bxjsbook", "付録"),
        ])
    func appendixInContents(row: (String, String)) {
        let tex = """
            \\documentclass{\(row.0)}\\begin{document}\\tableofcontents
            \\chapter{棚}\\appendix\\chapter{箱}\\end{document}
            """
        let body = LaTeXConverter.convert(tex).body
        let skip = #"<span class="latex-xkanjiskip"> </span>"#
        #expect(body.contains(##"<a href="#sec-A"><span class="secnum">"## + row.1 + skip + "A</span>箱</a>"))
        #expect(!body.contains(##"<a href="#sec-A"><span class="secnum">第"##))
    }

    @Test("付録の後に置いた目次でも、付録より前の章は「第 n 章」のまま載せる")
    func contentsAfterAppendix() {
        let tex = #"\documentclass{jbook}\begin{document}\chapter{棚}\appendix\chapter{箱}\tableofcontents\end{document}"#
        let body = LaTeXConverter.convert(tex).body
        #expect(body.contains(##"<a href="#sec-1"><span class="secnum">第 1 章</span>棚</a>"##))
        let appendix = ##"<a href="#sec-A"><span class="secnum">付 録<span class="latex-xkanjiskip"> </span>A</span>"##
        #expect(body.contains(appendix))
    }

    @Test("番号のない章と付録のあとの部は、目次で番号も付録の名前も付かない")
    func unnumberedEntriesAroundAppendix() {
        let tex = #"""
            \documentclass{jbook}\begin{document}\frontmatter\tableofcontents\chapter{序}
            \mainmatter\chapter{棚}\chapter*{星}\addcontentsline{toc}{chapter}{星}
            \appendix\chapter{箱}\part{後編}\chapter{末}\end{document}
            """#
        let body = LaTeXConverter.convert(tex).body
        #expect(body.contains(##"<a href="#sec-u1">序</a>"##))
        #expect(body.contains(##"<a href="#sec-u3">星</a>"##))
        #expect(body.contains(##"<a href="#part-1"><span class="secnum">I</span>後編</a>"##))
        let skip = #"<span class="latex-xkanjiskip"> </span>"#
        #expect(body.contains(##"<a href="#sec-B"><span class="secnum">付 録"## + skip + "B</span>末</a>"))
    }
}
