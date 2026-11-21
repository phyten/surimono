import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXLineParameterTests {
    @Test("段落の許容値と分綴の例外を前置きから読み、明示的な分綴位置だけ本文に残す")
    func preamble() throws {
        let source = #"""
            \documentclass{article}
            \sloppy\pretolerance=-1\tolerance 400\hyphenpenalty=72\exhyphenpenalty 99
            \linepenalty=11\adjdemerits=199\doublehyphendemerits 123\finalhyphendemerits=234
            \setlength{\emergencystretch}{2pt}\hyphenation{hy-phen proj-ect}\hyphenation{pro-ject}
            \frenchspacing\begin{document}One dis\-cretionary.\end{document}
            """#
        let result = LaTeXConverter.convert(source)
        let parameters = try parameters(in: #require(result.latexClass).initialLineParameters)
        #expect(parameters["tolerance"] as? Int == 400)
        #expect(parameters["pretolerance"] as? Int == -1)
        #expect(parameters["hyphenpenalty"] as? Int == 72)
        #expect(parameters["exhyphenpenalty"] as? Int == 99)
        #expect(parameters["linepenalty"] as? Int == 11)
        #expect(parameters["adjdemerits"] as? Int == 199)
        #expect(parameters["doublehyphendemerits"] as? Int == 123)
        #expect(parameters["finalhyphendemerits"] as? Int == 234)
        #expect(parameters["hyphenation"] as? String == "hy-phen proj-ect pro-ject")
        #expect(parameters["emergencystretch"] as? String == "calc(2 * var(--tex-pt, 0.996264pt))")
        #expect(parameters["frenchspacing"] as? Bool == true)
        #expect(result.body == "<p>One dis\u{00AD}cretionary.</p>\n")
        #expect(result.readingIssues.isEmpty)
    }

    @Test("本文の切り替えはその段落以降に効き、入れ子の指定は外側に漏れない")
    func body() throws {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{article}\begin{document}
            First.

            \sloppy Second.

            \fussy\pretolerance-1\emergencystretch=.5em\nonfrenchspacing Third{\tolerance=77}.

            Fourth.\end{document}
            """#)
        let paragraphs = result.body.split(separator: "\n").map(String.init)
        try #require(paragraphs.count == 4)
        #expect(paragraphs.first == "<p>First.</p>")
        #expect(paragraphs.last?.hasSuffix(">Fourth.</p>") == true)
        let second = try parameters(in: paragraphs[1])
        #expect(second["tolerance"] as? Int == 9999)
        #expect(second["emergencystretch"] as? String == "3em")
        let third = try parameters(in: paragraphs[2])
        #expect(third["tolerance"] as? Int == 200)
        #expect(third["pretolerance"] as? Int == -1)
        #expect(third["emergencystretch"] as? String == ".5em")
        #expect(third["frenchspacing"] as? Bool == false)
        #expect(paragraphs[2].hasSuffix(">Third.</p>"))
        #expect(try parameters(in: paragraphs[3])["tolerance"] as? Int == 200)
        #expect(result.readingIssues.isEmpty)
    }

    @Test("本文の許容値を変更しても入れ子リストの番号と段落構造を保つ")
    func nestedParagraphs() throws {
        let content = #"\begin{enumerate}\item First\begin{itemize}\item Inner\end{itemize}\end{enumerate}"#
        let normal = LaTeXConverter.convert(content).body
        let adjusted = LaTeXConverter.convert(#"\sloppy"# + content).body
        #expect(try parameters(in: adjusted)["tolerance"] as? Int == 9999)
        #expect(normal == adjusted.replacing(/\x20data-latex-line-parameters="[^"]+"/, with: ""))
    }

    @Test("数式と寸法式による代入も等号や数値を本文に出さない")
    func registerExpressions() throws {
        let result = LaTeXConverter.convert(
            #"\documentclass{article}\begin{document}\tolerance=\numexpr 300+20\relax\emergencystretch=\dimexpr 2pt+1pt\relax Text.\end{document}"#
        )
        let settings = try parameters(in: result.body)
        #expect(settings["tolerance"] as? Int == 320)
        #expect(settings["emergencystretch"] as? String == "calc(3 * var(--tex-pt, 0.996264pt))")
        #expect(result.body.hasSuffix(">Text.</p>\n"))
        #expect(result.readingIssues.isEmpty)
    }

    @Test("標準クラスは脚注書体の設計サイズと書誌内だけの文末空きを渡す", arguments: [10, 11, 12])
    func contextSettings(size: Int) throws {
        let info = LaTeXDocumentClassInfo(name: "article", options: "\(size)pt")
        let encoded = try #require(
            info.latinLineAttributes.firstMatch(of: /data-latex-context-parameters="([^"]+)"/)?.1)
        let settings = try #require(
            try JSONSerialization.jsonObject(with: Data(HTML.unescape(String(encoded)).utf8))
                as? [String: [String: Any]])
        #expect(settings["footnote"]?["fontSizePt"] as? Int == size - 2)
        #expect(settings["footnote"]?["firstIndentEm"] as? Double == 1.8)
        #expect(settings["footnote"]?["paragraphIndentEm"] as? Double == 1)
        for context in ["footnote", "bibliography", "caption", "minipage"] {
            #expect(settings[context]?["tolerance"] as? Int == 9999)
            #expect(settings[context]?["emergencystretch"] as? String == "3em")
        }
        #expect(settings["bibliography"]?["periodSpaceFactor"] as? Int == 1000)
        #expect(settings["footnote"]?["periodSpaceFactor"] == nil)
    }

    @Test("本文用フォントの後勝ちを脚注・書誌・概要の Times グルーにも反映する")
    func newTimesContexts() {
        let kit = #"\documentclass{article}\usepackage{aaai2027}"#
        #expect(
            LaTeXConverter.documentClassInfo(kit + #"\begin{document}"#).latinLineAttributes.contains(
                #"data-latex-context-glue="newtx""#))
        #expect(
            !LaTeXConverter.documentClassInfo(kit + #"\usepackage{times}\begin{document}"#).latinLineAttributes
                .contains("context-glue")
        )
        #expect(
            LaTeXConverter.documentClassInfo(
                #"\documentclass{article}\usepackage{cvpr}\usepackage{newtxtext}\begin{document}"#
            )
            .latinLineAttributes.contains(#"data-latex-context-glue="newtx""#))
    }

    @Test("本文の途中で選んだ段落設定を脚注本文の位置で記録する")
    func movedFootnotes() throws {
        let result = LaTeXConverter.convert(
            #"""
            \documentclass{article}\begin{document}
            Before\footnotemark.\par\frenchspacing\footnotetext{First note.}
            \nonfrenchspacing After\footnote{Second note.}
            \end{document}
            """#)
        let items = result.body.split(separator: "\n").filter { $0.hasPrefix("<li ") }
        try #require(items.count == 2)
        #expect(try parameters(in: String(items[0]))["frenchspacing"] as? Bool == true)
        #expect(try parameters(in: String(items[1]))["frenchspacing"] as? Bool == false)
    }

    @Test("URL のハイフンはパッケージ指定か学会キットの指定があるときだけ行分けを許可する")
    func urlHyphens() {
        let body = #"\begin{document}\url{https://example.org/a-b}\end{document}"#
        #expect(
            !LaTeXConverter.convert(#"\documentclass{article}\usepackage{url}"# + body).body.contains(
                "data-latex-url-hyphens"))
        for preamble in [#"\usepackage[hyphens]{url}"#, #"\usepackage{cvpr}"#] {
            #expect(
                LaTeXConverter.convert(#"\documentclass{article}"# + preamble + body).body.contains(
                    "data-latex-url-hyphens"))
        }
    }

    @Test("手書き文献のブロック間は糊を表し、openbib では別段落になる")
    func bibliographyBlocks() {
        let bib =
            #"\begin{document}\begin{thebibliography}{1}\bibitem{x}A. \newblock B.\end{thebibliography}\end{document}"#
        let standard = LaTeXConverter.convert(#"\documentclass{article}"# + bib)
        #expect(standard.body.contains("A. <span data-latex-newblock> </span>B."))
        let open = LaTeXConverter.convert(#"\documentclass[openbib]{article}"# + bib)
        #expect(open.body.contains("A.</p>\n<p>B.</p>"))
    }

    private func parameters(in tag: String) throws -> [String: Any] {
        let encoded = try #require(tag.firstMatch(of: /data-latex-line-parameters="([^"]+)"/)?.1)
        let json = Data(HTML.unescape(String(encoded)).utf8)
        return try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }
}
