import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZLineLayoutTests {
    // The inputs are TeX points. These tests exercise the production layout with
    // known glyph advances, without a font installation, DOM or pagination.
    private func context() throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript(try #require(DiagramScript.tikzLabelLayout))
        js.evaluateScript(
            #"""
            globalThis.layout = (text, zw, width, align = 'left', leading = 16) => {
              const widths = { A: 7.5, '1': 5, ' ': 3.33333 }; // cmr10.tfm at 10pt
              const atoms = text.split(/(\n)/).flatMap(labelParts).map(s => {
                const ja = japaneseGlyph.test(s);
                return {text:s, ja, zw, advance:ja ? zw : widths[s],
                  shrink:zw === 9.62216 ? .5 : .01 * zw, shift:0,
                  ascent:ja ? .88 * zw : 6.83331, depth:ja ? .12 * zw : 0};
              });
              return layoutLabel(atoms, width, leading, align);
            };
            globalThis.strings = out => out.lines.map(l => l.runs.map(r => r.atom.text).join(''));
            """#)
        try #require(js.evaluateScript("typeof layout")?.toString() == "function")
        return js
    }

    @Test("和文の三センチ枠を実測字幅から五行に分け、基線と箱を TeX 寸法に合わせる", arguments: [9.24713, 9.62216])
    func japaneseBox(zw: Double) throws {
        let js = try context()
        let input = "工程Aの記録を確認し、次の担当者へ渡す。作業リスト・チームを確認して保管する。"
        js.evaluateScript("const out = layout('\(input)', \(zw), 3 * 72.27 / 2.54)")
        let texts = try #require(js.evaluateScript("strings(out)")?.toArray() as? [String])
        #expect(texts == ["工程Aの記録を確", "認し、次の担当者へ", "渡す。作業リスト・", "チームを確認して保", "管する。"])
        #expect(js.evaluateScript("out.lines.map(l => l.y)")?.toArray() as? [Double] == [0, 16, 32, 48, 64])
        let h = try #require(js.evaluateScript("out.h")?.toDouble())
        #expect(abs(h - (64 + zw)) < 0.00001)
        #expect(js.evaluateScript("out.lines.every(l => l.width <= out.w + 1e-7)")?.toBool() == true)
    }

    @Test("一行でも和欧間に四分空きを置き、約物の横と行端には加えない")
    func glue() throws {
        let js = try context()
        let positions = js.evaluateScript("layout('日A、1本', 10, null).lines[0].runs.map(r => r.x)")
        #expect(positions?.toArray() as? [Double] == [0, 12.5, 20, 30, 37.5])
        #expect(
            js.evaluateScript("layout('日A', 10, 14, 'center').lines.map(l => l.x)")?.toArray() as? [Double] == [
                2, 3.25,
            ])
    }

    @Test("明示改行には指定した行送りを使い、合法な改行位置がないときは箱全体を断念する")
    func explicitBreaks() throws {
        let js = try context()
        js.evaluateScript(#"const manual = layout('日\nA', 10, null, 'right', 12)"#)
        #expect(js.evaluateScript("strings(manual)")?.toArray() as? [String] == ["日", "A"])
        #expect(js.evaluateScript("manual.lines.map(l => l.y)")?.toArray() as? [Double] == [0, 12])
        #expect(js.evaluateScript("manual.lines.map(l => l.x)")?.toArray() as? [Double] == [0, 2.5])
        js.evaluateScript("layout('「日」', 10, 20)")
        #expect(js.exception?.toString() == "Error: text width")
    }

    @Test("閉じ括弧・句読点・長音・小書きの仮名を行頭に出さず、開き括弧を行末に置かない")
    func prohibitedBreaks() throws {
        let js = try context()
        for character in "）」。、，．・：；？！ーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ" {
            let lines = js.evaluateScript("strings(layout('日本語\(character)次', 10, 30))")
            #expect(lines?.toArray() as? [String] == ["日本", "語\(character)次"])
        }
        #expect(js.evaluateScript("strings(layout('日本「都」', 10, 30))")?.toArray() as? [String] == ["日本", "「都」"])
    }
}
