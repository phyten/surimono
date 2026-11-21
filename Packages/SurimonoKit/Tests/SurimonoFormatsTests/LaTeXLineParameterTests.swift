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
    func nestedParagraphs() {
        let content = #"\begin{enumerate}\item First\begin{itemize}\item Inner\end{itemize}\end{enumerate}"#
        let normal = LaTeXConverter.convert(content).body
        let adjusted = LaTeXConverter.convert(#"\sloppy"# + content).body
        #expect(normal == adjusted)
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

    private func parameters(in tag: String) throws -> [String: Any] {
        let encoded = try #require(tag.firstMatch(of: /data-latex-line-parameters="([^"]+)"/)?.1)
        let json = Data(HTML.unescape(String(encoded)).utf8)
        return try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }
}
