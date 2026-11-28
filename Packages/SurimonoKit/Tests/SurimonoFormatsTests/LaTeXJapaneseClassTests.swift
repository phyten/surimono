import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXJapaneseClassTests {
    @Test("縦組みの tbook は奇数ページの左上・偶数ページの右上にノンブルを置き、偶数に章、奇数に節の柱を置く")
    func bookHeads() {
        var state = LaTeXPageNumbers(name: "tbook", options: [])
        state.apply("leftmark", value: "第1章 春")
        state.apply("rightmark", value: "1.1 庭")
        #expect(state.header == ["1", "", "1.1 庭"])
        #expect(state.footer == ["", "", ""])
        state.advance()
        #expect(state.header == ["第1章 春", "", "2"])
        state.apply("thispagestyle", value: "plain")
        #expect(state.header == ["", "", "2"])
    }

    @Test("縦組みの tarticle と treport は下の中央に、jlreq の縦組みは上の中央、本は上の小口側にノンブルを置く")
    func otherNumbers() {
        for name in ["tarticle", "utreport", "ltjtreport"] {
            let state = LaTeXPageNumbers(name: name, options: [])
            #expect(state.header == ["", "", ""], "\(name)")
            #expect(state.footer == ["", "1", ""], "\(name)")
        }
        let article = LaTeXPageNumbers(name: "jlreq", options: ["tate"])
        #expect(article.header == ["", "1", ""] && article.footer == ["", "", ""])
        var book = LaTeXPageNumbers(name: "jlreq", options: ["tate", "book"])
        #expect(book.header == ["1", "", ""])
        book.advance()
        #expect(book.header == ["", "", "2"])
        // The horizontal jlreq keeps its plain foot.
        #expect(LaTeXPageNumbers(name: "jlreq", options: []).footer == ["", "1", ""])
    }

    @Test("章ごとに番号を振り直す脚注は、文末の一覧で各章の最初の注に章の番号を付ける")
    func chapterNotes() throws {
        let fragment = LaTeXConverter.convert(
            #"""
            \documentclass{treport}
            \begin{document}
            \chapter{春}本文\footnote{春の注一。}と\footnote{春の注二。}
            \chapter{夏}本文\footnote{夏の注。}
            \end{document}
            """#)
        let notes = fragment.body.components(separatedBy: "<li id=\"fn-").dropFirst().map { $0.prefix(120) }
        try #require(notes.count == 3)
        #expect(notes[0].contains(#"data-latex-note-chapter="第1章""#))
        #expect(!notes[1].contains("data-latex-note-chapter"))
        #expect(notes[2].contains(#"data-latex-note-chapter="第2章""#))
    }

    @Test("章のない文書の脚注には章の番号を付けない")
    func articleNotes() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{tarticle}\begin{document}本文\footnote{注。}\section{節}本文\footnote{注。}\end{document}"#)
        #expect(!fragment.body.contains("data-latex-note-chapter"))
    }

    @Test("目次の節のページ番号を箱の始めに置くのは ltjsarticle だけで、jsarticle と bxjsarticle は箱の終わりにそろえる")
    func sectionPageNumbers() {
        func contents(_ name: String) -> String {
            let body = LaTeXConverter.convert(
                "\\documentclass{\(name)}\\begin{document}\\tableofcontents\\section{節}本文。\\end{document}"
            ).body
            return body.components(separatedBy: "<nav").dropFirst().first.map { String($0.prefix(200)) } ?? ""
        }
        #expect(contents("ltjsarticle").contains("data-latex-section-page-start"))
        #expect(!contents("bxjsarticle").contains("data-latex-section-page-start"))
        #expect(!contents("jsarticle").contains("data-latex-section-page-start"))
    }
}
