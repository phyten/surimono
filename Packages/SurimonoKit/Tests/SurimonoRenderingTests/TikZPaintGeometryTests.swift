import JavaScriptCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZPaintGeometryTests {
    private func geometry() throws -> JSContext {
        let context = try #require(JSContext())
        let script = try #require(DiagramScript.tikz)
        // These functions are hoisted before DOM preparation; exercise the actual painter without starting WebKit.
        context.evaluateScript(
            "(async () => { globalThis.tip = arrowTip; globalThis.offset = legendCellOffset; globalThis.row = legendRowHeight; return;\n"
                + script
                + "\n})()")
        try #require(context.exception == nil)
        return context
    }

    @Test("矢尻の外形寸法と軸を引く長さは PGF の指定に従う")
    func arrowDimensions() throws {
        let js = try geometry()
        js.evaluateScript(
            "const latex=tip('Latex', 6.2596, .7, 1), stealth=tip('Stealth', null, .8, 1), cm=tip('To', null, .4, 1), classic=tip('to', null, .4, 1)"
        )
        func n(_ expr: String) throws -> Double { try #require(js.evaluateScript(expr)?.toDouble()) }
        #expect(abs(try n("latex.width") - 4.6947) < 0.001)
        #expect(abs(try n("latex.retreat") - 5.9096) < 0.001)
        #expect(js.evaluateScript("!latex.rounded && latex.d.includes('C')")?.toBool() == true)
        #expect(abs(try n("stealth.width") - 4.95) < 0.001)
        #expect(abs(try n("stealth.length") - 6.6) < 0.001)
        #expect(abs(try n("cm.length") - 2.48) < 0.001)
        #expect(abs(try n("cm.width") - 5.2) < 0.001)
        #expect(abs(try n("classic.width") - 3.52) < 0.001)
        #expect(js.evaluateScript("cm.open && cm.rounded && !stealth.open")?.toBool() == true)
        #expect(js.exception == nil)
    }

    @Test("幅の違う二つの凡例文字を共通の列の中央・左端・右端に配置する")
    func legendOffsets() throws {
        let js = try geometry()
        #expect(js.evaluateScript("offset('center', 40 - 16)")?.toDouble() == 12)
        #expect(abs((js.evaluateScript("row(6.94444, 10, 1, 4)")?.toDouble() ?? 0) - 12.44444) < 0.0001)
        #expect(js.evaluateScript("offset('left', 40 - 16)")?.toDouble() == 0)
        #expect(js.evaluateScript("offset('right', 40 - 16)")?.toDouble() == 24)
    }
}
