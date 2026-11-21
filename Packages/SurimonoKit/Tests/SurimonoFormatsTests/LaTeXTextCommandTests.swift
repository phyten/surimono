import Foundation
import SurimonoFormats
import Testing

struct LaTeXTextCommandTests {
    @Test("未知の名前を出現順に一度だけ記録し、任意引数も警告も紙に出さない")
    func unknownCommands() {
        let result = LaTeXConverter.convert(
            #"\foo[hidden][x]{seen}[y]\begin{mystery}[width]body\end{mystery}\bar[secret]\foo{}"#)
        #expect(result.readingIssues == [#"commands not read: \foo, mystery, \bar"#])
        #expect(result.body == "<p>seen</p>\n<p>body</p>\n")
    }

    @Test(
        "未対応の持ち上げと回転は寸法と位置を消して内容だけを出す",
        arguments: [
            #"\raisebox{1em}[2em][3em]{word}"#, #"\rotatebox[origin=c]{45}{word}"#,
        ])
    func boxes(_ source: String) {
        let result = LaTeXConverter.convert(source)
        #expect(result.body == "<p>word</p>\n")
        #expect(result.readingIssues.isEmpty)
    }

    @Test("紙に出ない設定を引数ごと読み飛ばす")
    func setup() {
        let result = LaTeXConverter.convert(
            #"\settowidth{\test}{nil}\allowdisplaybreaks[4]\phantomsection\frenchspacing\phantom{invisible}X"#
        )
        #expect(result.body == "<p data-latex-line-parameters=\"{&quot;frenchspacing&quot;:true}\">X</p>\n")
        #expect(result.readingIssues.isEmpty)
    }

    @Test("PDF 用の代替文字と言語名は本文に出ない")
    func alternativeText() {
        #expect(
            LaTeXConverter.convert(#"\texorpdfstring{\foreignlanguage{english}{Text}}{hidden}"#).body
                == "<p><span lang=\"en\" dir=\"ltr\">Text</span></p>\n"
        )
    }

    @Test("ensuremath は本文中の式を組版する")
    func ensureMath() {
        #expect(LaTeXConverter.convert(#"\ensuremath{x^2}"#).body.contains("math math-inline"))
    }

    @Test("別々に書かれた脚注を印の順に組み合わせる")
    func footnotePairs() {
        let result = LaTeXConverter.convert(#"X\footnotemark Y\footnotemark\footnotetext{first}\footnotetext{second}"#)
        #expect(result.body.contains("<li id=\"fn-1\" value=\"1\"><p>first</p>"))
        #expect(result.body.contains("<li id=\"fn-2\" value=\"2\"><p>second</p>"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("外側の脚注が1番になり、その本文にある脚注が2番になる")
    func nestedFootnotes() {
        let html = LaTeXConverter.convert(#"本文\footnote{外側\footnote{内側}}"#).body
        #expect(html.contains(##"本文<sup class="footnote-ref"><a href="#fn-1" id="fnref-1">1</a></sup>"##))
        #expect(
            html.contains(
                ##"<li id="fn-1" value="1"><p>外側<sup class="footnote-ref"><a href="#fn-2" id="fnref-2">2</a>"##))
        #expect(html.contains(#"<li id="fn-2" value="2"><p>内側</p>"#))
    }

    @Test("番号を指定した脚注は対応する印へ戻し通常のカウンターを進めない")
    func explicitFootnote() {
        let result = LaTeXConverter.convert(#"X\footnotemark[8]\footnotemark\footnotetext{eight}\footnotetext[1]{one}"#)
        #expect(result.body.contains("<li id=\"fn-8\" value=\"8\"><p>eight</p>"))
        #expect(result.body.contains("<li id=\"fn-1\" value=\"1\"><p>one</p>"))
    }

    @Test("入れ子の強調は直立に戻り、その内側では再び斜体になる")
    func emphasis() {
        let html = LaTeXConverter.convert(#"\emph{A\emph{B\emph{C}}D}"#).body
        #expect(html.contains("<em>A<span style=\"font-style:normal\">B<em>C</em></span>D</em>"))
    }

    @Test("ハイライトに指定した色を使う")
    func highlight() {
        #expect(
            LaTeXConverter.convert(#"\sethlcolor{red}\hl{test}"#).body.contains(
                "<mark style=\"background-color:#ff0000\">test</mark>"))
    }

    @Test("大文字・小文字の変換は入れ子の書体タグを保つ")
    func caseConversion() {
        let result = LaTeXConverter.convert(
            #"\MakeUppercase{\textbf{Word}}/\lowercase{LOW}/\uppercase{up}/\MakeLowercase{HIGH}"#)
        #expect(result.body.contains("<strong>WORD</strong>/low/UP/high"))
    }

    @Test("上下付きの文字を本文の書体のまま組む")
    func superscriptAndSubscript() {
        #expect(
            LaTeXConverter.convert(#"x\textsuperscript{2}y\textsubscript{n}"#).body
                == "<p>x<sup>2</sup>y<sub>n</sub></p>\n")
    }

    @Test("TeX のロゴ名はそのまま読める文字になる")
    func logos() {
        let html = LaTeXConverter.convert(#"\TeX/\LaTeX/\LaTeXe"#).body
        #expect(
            html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) == "TeX/LaTeX/LaTeX2ε\n")
    }

    @Test("today の年月日は文書クラスの言語で表す")
    func today() {
        let ja = LaTeXConverter.convert(#"\documentclass{jsarticle}\begin{document}\today\end{document}"#)
        #expect(ja.body.range(of: #"<p>\d{4}年\d{1,2}月\d{1,2}日</p>"#, options: .regularExpression) != nil)
        let en = LaTeXConverter.convert(#"\today"#)
        #expect(en.body.range(of: #"<p>[A-Z][a-z]+ \d{1,2}, \d{4}</p>"#, options: .regularExpression) != nil)
    }

    @Test("未知のコマンドの二つ目の本文の後でも任意引数を落とす")
    func interleavedOptions() {
        #expect(LaTeXConverter.convert(#"\missing{one} {two}[hidden]!"#).body == "<p>one two!</p>\n")
    }

    @Test("同梱の LaTeX 見本に未知のコマンドが残らない")
    func sample() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let result = LaTeXConverter.convert(
            try String(contentsOf: url.appending(path: "Samples/sample.tex"), encoding: .utf8))
        #expect(result.readingIssues.isEmpty)
        #expect(result.body.contains("<span class=\"tikz-block\""))
        #expect(result.body.contains("星と月の展示です。"))
        #expect(!result.body.contains("Astronomy exhibit."))
    }
}
