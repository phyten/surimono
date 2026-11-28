import Foundation
import JavaScriptCore
import Testing

@testable import SurimonoFormats
@testable import SurimonoRendering

/// The plot marks are drawn by Swift (PGFPlotsPlane) and their legend glyphs by tikz.js. These
/// tests read both outlines and compare them, so one side cannot change without the other.
@MainActor
struct PlotMarkContractTests {
    private struct Outline: Equatable {
        var circle = false
        var filled = false
        var paths: [(points: [[Double]], close: Bool)] = []

        static func == (a: Outline, b: Outline) -> Bool {
            a.circle == b.circle && a.filled == b.filled && a.paths.count == b.paths.count
                && zip(a.paths, b.paths).allSatisfy { p, q in
                    p.close == q.close && p.points.count == q.points.count
                        && zip(p.points, q.points).allSatisfy { abs($0[0] - $1[0]) < 1e-6 && abs($0[1] - $1[1]) < 1e-6 }
                }
        }
    }

    private func script() throws -> JSContext {
        let js = try #require(JSContext())
        let script = try #require(DiagramScript.tikz)
        // Function declarations are hoisted, so the early return exposes them without painting anything.
        js.evaluateScript(
            "(async () => { globalThis.plotMarkShape = plotMarkShape; globalThis.mathAttribute = mathAttribute;"
                + " globalThis.mathElement = mathElement; return;\n" + script + "\n})()")
        try #require(js.evaluateScript("typeof plotMarkShape")?.toString() == "function")
        return js
    }

    private func legend(_ mark: String, in js: JSContext) throws -> Outline {
        let json = try #require(js.evaluateScript("JSON.stringify(plotMarkShape(\(literal(mark))))")?.toString())
        let shape = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let paths = try #require(shape["paths"] as? [[String: Any]])
        return Outline(
            circle: shape["circle"] as? Bool ?? false, filled: shape["filled"] as? Bool ?? false,
            paths: try paths.map {
                (try #require($0["points"] as? [[Double]]), $0["close"] as? Bool ?? false)
            })
    }

    /// Reads the TikZ commands drawMark writes for one mark, relative to its center in units of its size.
    private func plot(_ mark: String) throws -> Outline {
        // A filled circle at the same point gives the center; its radius is the mark size.
        let source = try PGFPlots.lower(
            environment: "axis", options: "xtick={},ytick={}",
            body: "\\addplot[only marks,mark=*] coordinates {(0,0)};"
                + "\\addplot[only marks,mark=\(mark)] coordinates {(0,0)};"
        ).source
        let lines = source.split(separator: "\n").filter { $0.contains("solid") }
        func points(_ text: Substring) -> [[Double]] {
            text.matches(of: /\((-?[0-9.e+-]+)pt,(-?[0-9.e+-]+)pt\)/).compactMap { match in
                guard let x = Double(match.1), let y = Double(match.2) else { return nil }
                return [x, y]
            }
        }
        let first = try #require(lines.first)
        let center = try #require(points(first).first)
        let radius = try #require(first.firstMatch(of: /circle \(([0-9.]+)pt\)/).flatMap { Double($0.1) })
        func unit(_ p: [Double]) -> [Double] { [(p[0] - center[0]) / radius, (p[1] - center[1]) / radius] }
        var outline = Outline()
        for (index, line) in lines.dropFirst().enumerated() {
            if index == 0 { outline.filled = line.hasPrefix(#"\filldraw"#) }
            let body = try #require(line.split(separator: "] ", maxSplits: 1).last)
            if body.contains(" circle (") {
                outline.circle = true
            } else if body.contains(" rectangle ") {
                let corners = points(body).map(unit)
                try #require(corners.count == 2)
                let (a, b) = (corners[0], corners[1])
                outline.paths.append(([a, [b[0], a[1]], b, [a[0], b[1]]], true))
            } else {
                for subpath in body.dropLast().split(separator: " ") {
                    outline.paths.append((points(subpath).map(unit), subpath.hasSuffix("--cycle")))
                }
            }
        }
        return outline
    }

    private func literal(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
    }

    @Test("凡例の印は本体の印と同じ輪郭・円・塗りを持つ", arguments: PGFPlotsPlane.marks.sorted())
    func sameOutline(mark: String) throws {
        let js = try script()
        #expect(try legend(mark, in: js) == plot(mark))
        #expect(js.exception == nil)
    }

    @Test("数式の SVG の写しは data 属性を捨て、表示用の属性だけを通す")
    func mathBoundary() throws {
        let js = try script()
        func verdict(_ call: String) -> String? {
            js.evaluateScript("(() => { try { return String(\(call)); } catch (e) { return 'rejected'; } })()")?
                .toString()
        }
        #expect(verdict(#"mathAttribute("data-math-glue", "3,10;1,2.5,4")"#) == "false")
        #expect(verdict(##"mathAttribute("fill", "#000000")"##) == "true")
        #expect(verdict(#"mathAttribute("font-family", "KaTeX_Main")"#) == "true")
        for call in [
            #"mathAttribute("onload", "alert(1)")"#, ##"mathAttribute("href", "#a")"##,
            ##"mathAttribute("xlink:href", "#a")"##, #"mathAttribute("font-family", "Arial")"#,
            #"mathAttribute("fill", "url(javascript:alert(1))")"#,
        ] {
            #expect(verdict(call) == "rejected", "\(call)")
        }
        for element in ["script", "foreignObject", "image", "use", "a"] {
            #expect(verdict("mathElement(\(literal(element)))") == "false", "\(element)")
        }
        #expect(verdict(#"mathElement("path")"#) == "true")
    }
}
