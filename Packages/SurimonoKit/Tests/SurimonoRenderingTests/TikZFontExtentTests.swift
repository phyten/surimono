import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZFontExtentTests {
    @Test("標準欧文の節点は各文字の TeX 高さと深さだけを含む")
    func glyphBoxes() throws {
        let js = try #require(JSContext())
        let script = try #require(DiagramScript.tikz)
        js.evaluateScript("(async () => { globalThis.box = cmrExtent; return;\n" + script + "\n})()")
        func dimension(_ expression: String) throws -> Double {
            try #require(js.evaluateScript(expression)?.toDouble())
        }
        #expect(abs(try dimension("10 * box('Hg').ascent") - 6.83331) < 0.0001)
        #expect(abs(try dimension("10 * box('Hg').depth") - 1.94444) < 0.0001)
        #expect(abs(try dimension("10 * box('Collect').ascent") - 6.94444) < 0.0001)
        #expect(try dimension("box('Collect').depth") == 0)
        #expect(js.evaluateScript("box('日本語') === null")?.toBool() == true)
        #expect(js.exception == nil)
    }
}
