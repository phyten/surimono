import Testing

@testable import SurimonoFormats

struct LaTeXPageNumberTests {
    @Test("前置きは初期値になり、本文の番号の宣言は文章の途中に測定位置を残す")
    func preambleAndBody() throws {
        let doc = LaTeXConverter.convert(
            #"""
            \documentclass{article}\pagenumbering{alph}\setcounter{page}{3}
            \begin{document}A\thispagestyle{empty}B\pagenumbering{arabic}C\end{document}
            """#)
        #expect(doc.latexClass?.pageNumbers.label == "c")
        #expect(doc.latexClass?.pageNumbers.showsFooter == true)
        #expect(doc.body.contains(#"A<span data-latex-page-action="thispagestyle" data-value="empty"></span>B"#))
        #expect(doc.body.contains(#"data-latex-page-action="pagenumbering" data-value="arabic""#))
    }

    @Test("空の柱と fancy の空指定を読み、中央の thepage と headings で番号が戻る")
    func footerDeclarations() {
        func visible(_ settings: String) -> Bool {
            LaTeXConverter.documentClassInfo("\\documentclass{article}" + settings + "\\begin{document}").pageNumbers
                .showsFooter
        }
        #expect(!visible(#"\pagestyle{empty}"#))
        #expect(!visible(#"\pagestyle{fancy}\fancyfoot{}"#))
        #expect(visible(#"\pagestyle{fancy}\fancyhf{}\cfoot{\thepage}"#))
        #expect(visible(#"\pagestyle{empty}\pagestyle{headings}"#))
    }

    @Test("柱の三つの位置と奇偶別の指定を読み、番号のない文字だけの柱も残す")
    func fancyFields() {
        var state = LaTeXConverter.documentClassInfo(
            #"""
            \documentclass[twoside]{article}\pagestyle{fancy}\fancyhf{}
            \lhead{Model workshop}\rhead{Crew sheet}\cfoot{\thepage}
            \fancyhead[ER]{Sheet \thepage}\lfoot[Even]{Odd}\pagenumbering{roman}\begin{document}
            """#
        ).pageNumbers
        #expect(state.header == ["Model workshop", "", "Crew sheet"])
        #expect(state.footer == ["Odd", "i", ""])
        state.advance()
        #expect(state.header == ["Model workshop", "", "Sheet ii"])
        #expect(state.footer == ["Even", "ii", ""])
        state.apply("fancy:F", value: "")
        #expect(!state.showsFooter)
        #expect(state.header[2] == "Sheet ii")
    }

    @Test("会議論文の既定の柱と開状・表題がそのページだけに選ぶ柱を区別する")
    func classPages() {
        for declaration in ["[conference]{IEEEtran}", "{llncs}"] {
            var state = LaTeXConverter.documentClassInfo("\\documentclass" + declaration).pageNumbers
            #expect(!state.showsFooter)
            state.advance()
            #expect(!state.showsFooter)
            state.apply("pagestyle", value: "plain")
            #expect(state.footer == ["", "2", ""])
        }
        for (declaration, title) in [
            ("{letter}", #"\begin{letter}{Depot}\opening{Hello}\end{letter}"#),
            ("[preprint]{elsarticle}", #"\begin{frontmatter}\title{Trial}\end{frontmatter}"#),
        ] {
            let fragment = LaTeXConverter.convert(
                "\\documentclass" + declaration + "\\begin{document}" + title + "\\end{document}")
            #expect(fragment.body.contains(#"data-latex-page-action="thispagestyle" data-value="empty""#))
            #expect(fragment.latexClass?.pageNumbers.footer == ["", "1", ""])
        }
    }

    @Test("名前を付けた柱は選んだ時点で基底の欄を引き継ぎ、このページだけの指定は次に持ち越さない")
    func namedStyles() {
        var state = LaTeXConverter.documentClassInfo(
            #"""
            \documentclass{article}\pagestyle{fancy}\fancyhf{}\lhead{Workshop}
            \fancypagestyle{crew}{\rhead{Crew}\cfoot{\thepage}}
            \fancypagestyle{card}[crew]{\lfoot{Card}}
            \fancypagestyle{plain}{\fancyhf{}\rhead{Page \thepage}}
            \begin{document}
            """#
        ).pageNumbers
        #expect(state.header == ["Workshop", "", ""])
        state.apply("thispagestyle", value: "card")
        #expect(state.header == ["Workshop", "", "Crew"])
        #expect(state.footer == ["Card", "1", ""])
        state.advance()
        #expect(state.header == ["Workshop", "", ""])
        #expect(!state.showsFooter)
        state.apply("classPlain", value: "")
        #expect(state.header == ["", "", "Page 2"])
        state.advance()
        state.apply("pagestyle", value: "crew")
        #expect(state.header == ["Workshop", "", "Crew"])
        state.advance()
        state.apply("pagestyle", value: "fancy")
        #expect(state.footer == ["", "4", ""])
    }

    @Test("本文で定義した柱を前置きへ繰り上げず、文字や設定を本文に出さない")
    func bodyStyle() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{article}\begin{document}A\fancypagestyle{crew}{\fancyhf{}\rfoot{Last \thepage}}\thispagestyle{crew}B\end{document}"#
        )
        #expect(
            DocumentOutline.plainText(ofHTML: fragment.body).trimmingCharacters(in: .whitespacesAndNewlines) == "AB")
        var state = try #require(fragment.latexClass?.pageNumbers)
        #expect(state.footer == ["", "1", ""])
        state.advance()
        for case .tag(let tag) in HTMLScanner.tokens(fragment.body) {
            if let action = tag.attribute("data-latex-page-action"), let value = tag.attribute("data-value") {
                state.apply(action, value: value)
            }
        }
        #expect(state.footer == ["", "", "Last 2"])
        state.advance()
        #expect(state.footer == ["", "3", ""])
    }

    @Test("本文の柱の文字は目印の属性に閉じ込め、本文に混ぜない")
    func escapeHeader() {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{article}\begin{document}A\fancyhead[L]{a" <b> & c}B\end{document}"#)
        #expect(fragment.body.contains("a&quot; &lt;b&gt; &amp; c"))
        #expect(DocumentOutline.plainText(ofHTML: fragment.body).contains("AB"))
    }
}
