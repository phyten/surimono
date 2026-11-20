import JavaScriptCore
import Testing

@testable import SurimonoRendering

struct LaTeXDisplayGeometryTests {
    @Test("解答罫は指定の高さに収まる本数を中央に配し、再測定しても増えない")
    func answerRulePitch() throws {
        let js = try #require(JSContext())
        js.evaluateScript(
            """
            const path = {fontSize: '22.5px', setAttribute(k,v) { this[k] = v; }};
            const svg = {height: '63.78px', querySelector: () => path, setAttribute(k,v) { this[k] = v; }};
            const document = {documentElement: {style: {}}, querySelectorAll: () => [svg]};
            const getComputedStyle = el => el;
            """)
        let script = try #require(LaTeXGraphicPreparation.script(in: "<svg data-exam-rules ", layoutWidth: 500))
        for _ in 0..<2 { js.evaluateScript(script) }
        #expect(js.exception == nil)
        let starts = try #require(
            js.evaluateScript("path.d.match(/M0 [^ ]+/g).map(s => +s.slice(3))")?.toArray() as? [Double])
        try #require(starts.count == 2)
        #expect(abs(starts[0] - 31.89) < 0.001)
        #expect(abs(starts[1] - starts[0] - 22.5) < 0.001)
    }

    @Test("数式 SVG の字面が上下にはみ出せば行の実寸に取り込み、行番号を同じ位置に保つ")
    func inkBounds() throws {
        let js = try #require(JSContext())
        js.evaluateScript(
            """
            const label = {style:{top:'50%'}};
            const svg = {
              viewBox:{baseVal:{x:0,y:0,width:80,height:20}},
              width:{baseVal:{unitType:3,valueInSpecifiedUnits:8}},
              height:{baseVal:{unitType:3,valueInSpecifiedUnits:2}},
              style:{verticalAlign:'-0.4em'}, dataset:{},
              parentElement:{dataset:{}, closest:() => ({}), querySelectorAll:() => [label]},
              getBBox:() => ({x:-1,y:-3,width:81,height:25}),
              setAttribute(key,value) {
                if (key === 'viewBox') {
                  const [x,y,width,height] = value.split(' ').map(Number);
                  this.viewBox.baseVal = {x,y,width,height};
                } else this[key].baseVal.valueInSpecifiedUnits = parseFloat(value);
              }
            };
            const document = {querySelectorAll:() => [svg]};
            """)
        for _ in 0..<2 { js.evaluateScript(LaTeXGraphicPreparation.measureDisplays) }
        #expect(js.exception == nil)
        #expect(js.evaluateScript("svg.viewBox.baseVal.y")?.toDouble() == -3)
        #expect(js.evaluateScript("svg.height.baseVal.valueInSpecifiedUnits")?.toDouble() == 2.5)
        #expect(js.evaluateScript("svg.dataset.latexTexTop")?.toDouble() == 0)
        #expect(js.evaluateScript("svg.dataset.latexTexBottom")?.toDouble() == 20)
        #expect(js.evaluateScript("svg.dataset.latexTexFirst")?.toDouble() == 16)
        #expect(js.evaluateScript("svg.dataset.latexTexLast")?.toDouble() == 16)
        #expect(js.evaluateScript("label.style.top")?.toString() == "52%")
        #expect(js.evaluateScript("svg.style.overflow")?.toString() == "hidden")
        #expect(LaTeXGraphicPreparation.script(in: "<p>文章</p>", layoutWidth: 500) == nil)
    }
}
