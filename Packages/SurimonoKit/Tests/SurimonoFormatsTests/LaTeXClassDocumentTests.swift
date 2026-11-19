import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXClassDocumentTests {
    @Test("開状の有無によらず各手紙の先頭だけを無ノンブルにし、続頁には通常の柱を使う")
    func firstLetterPage() throws {
        let fragment = LaTeXConverter.convert(
            #"\documentclass{letter}\begin{document}\begin{letter}{Depot}\opening{Dear team,}One\end{letter}\begin{letter}{Shop}Two\end{letter}\end{document}"#
        )
        let letters = fragment.body.components(separatedBy: #"data-latex-break="clear""#)
        try #require(letters.count == 2)
        for letter in letters {
            #expect(letter.ranges(of: #"data-latex-page-action="thispagestyle" data-value="empty""#).count == 1)
        }
        var pages = try #require(fragment.latexClass?.pageNumbers)
        pages.apply("thispagestyle", value: "empty")
        #expect(!pages.showsFooter)
        pages.advance()
        #expect(pages.footer == ["", "2", ""])
    }

    @Test("手紙の差出人・宛先・日付・署名・追伸と同封物を別々の段落で読む")
    func letter() {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{letter}\signature{Fixture desk}\address{Workshop\\East}\date{14 May}
            \begin{document}\begin{letter}{Stores\\Model Workshop}\opening{Dear team,}
            Paper.\closing{Thanks,}\ps Postscript.\cc{Shop}\encl{Stock list}\end{letter}
            \begin{letter}{New client}\opening{Hello}\closing{Bye}\end{letter}\end{document}
            """#)
        let order = [
            "Workshop<br>East", "14 May", "Stores<br>Model Workshop", "Dear team,", "Paper.", "Thanks,",
            "Fixture desk", "Postscript.", "cc: Shop", "encl: Stock list", "New client", "Hello", "Bye",
        ]
        var remaining = result.body[...]
        for token in order {
            guard let range = remaining.range(of: token) else {
                Issue.record("手紙の本文に \(token) がない")
                return
            }
            remaining = remaining[range.upperBound...]
        }
        #expect(result.body.components(separatedBy: #"data-latex-break="clear""#).count == 2)
    }

    @Test("履歴書の連絡先・写真・ラベル・経歴・複列の項目を保つ")
    func cv() {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{moderncv}\moderncvstyle{other}\moderncvcolor{burgundy}
            \name{Model}{Workshop}\title{Projects}\address{East}{City}{Country}\phone[mobile]{123}
            \email{me@example.com}\homepage{example.com}\social[github]{fixture}\extrainfo{Desk}\photo[25mm]{face}
            \begin{document}\makecvtitle\section{Trials}\cventry{2025}{Rail spacer}{Fixture desk}{Town}{A}{Measured twice.}
            \cvitem{Tool}{Rule}\cvitemwithcomment{Reading}{Passed}{checked}\cvdoubleitem{Left}{red}{Right}{blue}
            \cvlistitem{one}\cvlistdoubleitem{two}{three}\unknown{kept}\end{document}
            """#, directory: URL(filePath: "/cv"), imageExists: { $0.lastPathComponent == "face.png" })
        for text in [
            "Model Workshop", "Projects", "East<br>City<br>Country", "mobile: 123", "me@example.com",
            "example.com", "github: fixture", "Desk", "face.png", "2025</div>", "Rail spacer</strong>",
            "<em>Fixture desk</em>, Town, A", "Measured twice.", "Trials", "Tool", "Rule", "checked",
            "Left", "Right", "red", "blue", "• one", "• two", "• three", "kept",
        ] {
            #expect(result.body.contains(text))
        }
        #expect(result.latexClass?.pointSize == 11)
        #expect(result.latexClass?.styleVariables.contains("--latex-cv-ink: #980000") == true)
    }

    @Test("アラビア語の基本双方向モードでは列を左から、セルを右から読む")
    func basicArabicTable() {
        let table =
            #"\babelprovide[import,main]{arabic}\begin{document}\begin{tabular}{cr}1&12\\2&18\end{tabular}\end{document}"#
        let basic = LaTeXConverter.convert(#"\documentclass{article}\usepackage[bidi=basic]{babel}"# + table).body
        #expect(basic.contains(#"<table dir="ltr" class="latex-tabular""#))
        #expect(basic.contains(#"<td dir="rtl" style="text-align: end"#))
        #expect(
            !LaTeXConverter.convert(#"\documentclass{article}\usepackage{babel}"# + table).body.contains(
                #"<table dir="ltr""#))
    }

    @Test("本文全体を横置きしたときだけ版面の縦横を交換する")
    func landscape() {
        let prefix = #"\documentclass{article}\begin{document}"#
        let wide = #"\begin{landscape}Wide\end{landscape}"#
        let plain = LaTeXConverter.documentClassInfo(prefix + #"Narrow\end{document}"#).pageBox
        let all = LaTeXConverter.documentClassInfo(prefix + "% note\n" + wide + #"\end{document}"#).pageBox
        #expect(all.paperWidth == plain.paperHeight)
        #expect(abs(all.textWidth - plain.textHeight) < 0.0001)
        let consecutive = LaTeXConverter.convert(prefix + #"\pagestyle{plain}"# + wide + wide + #"\end{document}"#)
        #expect(consecutive.latexClass?.pageBox == all)
        #expect(consecutive.body.components(separatedBy: #"data-latex-break="clear""#).count == 2)
        for body in ["Intro" + wide, wide + "Tail", #"\verb|\begin{landscape}|"#] {
            #expect(LaTeXConverter.documentClassInfo(prefix + body + #"\end{document}"#).pageBox == plain)
        }
    }

    @Test("表の改行の追加寸法は直前の行に、水平空きと段落・項目の寸法は同じ物理単位に変換する")
    func dimensions() throws {
        let result = LaTeXConverter.convert(
            #"\documentclass{article}\setlength{\parskip}{3pt}\setlength{\itemsep}{3pt}\begin{document}A\hspace{3pt}B\begin{tabular}{p{3pt}}X\\[3pt]Y\end{tabular}\end{document}"#
        )
        let length = try #require(LaTeXSymbols.printLength("3pt"))
        #expect(LaTeXSymbols.printLength("196608sp") == length)
        #expect(result.body.contains("width: " + length))
        #expect(result.body.contains("--latex-row-skip: " + length))
        #expect(!result.body.contains("[3pt]"))
        #expect(result.latexClass?.styleVariables.contains("--latex-parskip: " + length) == true)
        #expect(result.latexClass?.styleVariables.contains("--latex-itemsep: " + length) == true)
    }
}
