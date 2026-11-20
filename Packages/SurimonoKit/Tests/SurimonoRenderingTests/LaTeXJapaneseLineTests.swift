import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXJapaneseLineTests {
    @Test("十一ポイント・余白二十五ミリの本文は全角四十五字を収め、行末の約物を次行に残さない")
    func referenceLines() throws {
        let js = try #require(JSContext())
        js.evaluateScript(try LaTeXFlowPaginator.japaneseLineScript())
        js.evaluateScript(
            """
            function wrap(text, indent) {
                const plan = planJapaneseProse(text, 455.24411, indent, 10.95, 10.12563, word => word.length * 8.2125);
                return plan?.lines.map(line => plan.tokens.slice(line.start, line.end).map(t => t.text).join(''));
            }
            """)
        let full = String(repeating: "折紙窓札", count: 15)
        let marks = "東の「紙窓」、西の「細板」、青の「角札」、赤の「端板」、白の「折板」、奥の「紙窓」、手前の「角札」、"
        for (text, indent, first) in [
            (full, 0.0, String(full.prefix(45))),
            (full, 10.12563, String(full.prefix(44))),
            (marks + "南の「折板」。", 0, marks),
        ] {
            js.setObject(text, forKeyedSubscript: "sample" as NSString)
            let lines = try #require(js.evaluateScript("wrap(sample, \(indent))")?.toArray() as? [String])
            #expect(lines.first == first)
            #expect(lines.joined() == text)
        }
        #expect(js.evaluateScript("wrap('紙' + 'a'.repeat(90) + '紙', 0) === undefined")?.toBool() == true)
    }
}
