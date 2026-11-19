import JavaScriptCore
import Testing

@testable import SurimonoRendering

struct LaTeXDisplayGeometryTests {
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
              style:{}, parentElement:{querySelectorAll:() => [label]},
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
        #expect(js.evaluateScript("label.style.top")?.toString() == "52%")
        #expect(js.evaluateScript("svg.style.overflow")?.toString() == "hidden")
        #expect(LaTeXGraphicPreparation.script(in: "<p>文章</p>", layoutWidth: 500) == nil)
    }
}
