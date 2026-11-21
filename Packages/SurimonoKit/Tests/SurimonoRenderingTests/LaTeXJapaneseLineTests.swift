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

    @Test("文献中の全角コロンを半角字面と左右四分の一字の伸縮可能な空きで計る")
    func bibliographyPunctuation() throws {
        let js = try #require(JSContext())
        js.evaluateScript(try LaTeXFlowPaginator.japaneseLineScript())
        let widths =
            js.evaluateScript(
                """
                (() => {
                    const tokens = [];
                    japaneseGridTokens('紙：芯', tokens, 7, 10, () => 10);
                    const plan = japaneseBreakPlan(tokens, 30, 0, 7, 10, true);
                    return [tokens[1].advance, ...plan.gaps[1], ...plan.gaps[2]];
                })()
                """
            )?.toArray() as? [Double]
        #expect(widths == [5, 2.5, 0, 2.5, 2.5, 0, 2.5])
    }

    @Test("学会誌の二十四字・二十六字詰めは句読点を詰め、数値と単位を同じ行に残す")
    func journalParagraphs() throws {
        let js = try #require(JSContext())
        js.evaluateScript(try LaTeXFlowPaginator.japaneseLineScript())
        js.evaluateScript(
            """
            function wrapJournal(source, em, zw, width) {
                const tokens = [];
                japaneseGridTokens(source, tokens, em, zw, word => word.length * em * .51);
                const plan = japaneseBreakPlan(tokens, width, zw, em, zw, true);
                return plan?.lines.map(({start,end}) => tokens.slice(start,end).map(t => t.text).join(''));
            }
            """)
        let source =
            "鉄道の紙模型には，高さの正確な小さな部品が数多く必要である． 線路，ホームの縁，信号機の台座はいずれもスペーサーの上に載り，"
            + "スペーサーが1 mmの何分の一か厚いだけで，線路の継ぎ目が持ち上がり軽い貨車が脱線する．"
        js.setObject(source, forKeyedSubscript: "source" as NSString)
        for (dimensions, first, second) in [
            ("9.61035,9.24722,240.1189", "鉄道の紙模型には，高さの正確な小さな部品が数多く必", "要である． 線路，ホームの縁，信号機の台座はいずれもス"),
            ("9,8.536,204.864", "鉄道の紙模型には，高さの正確な小さな部品が数多", "く必要である． 線路，ホームの縁，信号機の台座はい"),
        ] {
            let lines = try #require(js.evaluateScript("wrapJournal(source, \(dimensions))")?.toArray() as? [String])
            #expect(Array(lines.prefix(2)) == [first, second])
            #expect(lines.contains { $0.contains("1 mm") })
            #expect(lines.joined() == source)
        }
    }
}
