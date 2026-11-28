import JavaScriptCore
import Testing

@testable import SurimonoRendering

struct LaTeXEquationTagsTests {
    /// A minimal DOM: each equation is one centred or indented display with a single number.
    private func run(_ equations: String) throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript(
            #"""
            function equation({z, w, e, left, pad = 0, mode = 'horizontal-tb'}) {
              const tag = {getBoundingClientRect: () => ({width: e})};
              const svg = {getBoundingClientRect: () => ({width: w, left, right: left + w})};
              const math = {clientWidth: z, css: {paddingLeft: pad + 'px', paddingRight: '0px'},
                getBoundingClientRect: () => ({width: z, left: 0, right: z}), querySelector: () => svg};
              const props = {};
              const eq = {dataset: {}, css: {fontSize: '10px', writingMode: mode, getPropertyValue: () => ''},
                style: {setProperty: (k, v) => { props[k] = v; }, removeProperty: k => { delete props[k]; }},
                props,
                removeAttribute(name) {
                  const key = name.slice(5).replace(/-(.)/g, (_, c) => c.toUpperCase());
                  delete this.dataset[key];
                },
                querySelector(selector) {
                  if (selector.includes('row-number')) return null;
                  if (selector.includes('svg')) return svg;
                  return selector.includes('eqno') ? tag : math;
                }};
              return eq;
            }
            const getComputedStyle = el => el.css;
            """#)
        js.evaluateScript("const equations = [\(equations)];")
        js.evaluateScript(LaTeXEquationTags.definition)
        js.evaluateScript("surimonoFitEquationTags({querySelectorAll: () => equations});")
        #expect(js.exception == nil)
        return js
    }

    @Test("横組みで中央に置いた式だけ、行に入らない番号を別の行へ送る")
    func centredDisplayOnly() throws {
        let js = try run(
            """
            equation({z: 100, w: 95, e: 10, left: 2.5}),
            equation({z: 100, w: 70, e: 10, left: 20, pad: 20}),
            equation({z: 100, w: 95, e: 10, left: 2.5, mode: 'vertical-rl'}),
            equation({z: 100, w: 60, e: 10, left: 0})
            """)
        let lines = js.evaluateScript("equations.map(eq => eq.dataset.latexTagLine ?? '')")?.toArray() as? [String]
        #expect(lines == ["below", "", "", ""])
        // mathindent, tag insets and vertical text keep their own geometry; neither attribute is written.
        let rooms = js.evaluateScript("equations.map(eq => eq.dataset.latexTagRoom ?? '')")?.toArray() as? [String]
        #expect(rooms == ["", "", "", ""])
    }
}
