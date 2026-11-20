import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZLabelRenderingTests {
    @Test("固定図の内側にある和文ラベルは矩形の外寸を増やさない", .timeLimit(.minutes(1)))
    func interiorLabel() async throws {
        let tex = #"""
            \documentclass[a4paper,10pt,oneside]{ltjsreport}\linespread{1.15}\usepackage{tikz,float}
            \begin{document}\begin{figure}[H]\centering\begin{tikzpicture}
            \draw[line width=1pt] (0,0) rectangle (4,2);\node at (2,1) {測定};
            \draw[->,line width=2pt] (.4,.5)--(1.4,.5);
            \end{tikzpicture}\caption{紙帯}\end{figure}\end{document}
            """#
        let root = try #require(try await render(tex, theme: "latex-plain-ja").rootElement())
        for (name, expected) in [("width", 114.382), ("height", 57.689)] {
            let length = try #require(root.attribute(forName: name)?.stringValue)
            // DiagramGeometry serializes absolute SVG dimensions in CSS pixels.
            let points = try #require(Double(length)) * 72 / 96
            #expect(abs(points - expected) < 0.1)
        }
    }

    @Test("一行の枠に本文行の上下の空きを足さず、文字の深さを保つ", .timeLimit(.minutes(1)))
    func singleLine() async throws {
        let source = #"""
            \documentclass{article}\begin{document}
            \begin{tikzpicture}\node[draw,inner sep=3pt] {Hg};\end{tikzpicture}
            \end{document}
            """#
        let xml = try await render(source, theme: "latex-article")
        let rect = try #require(xml.nodes(forXPath: "//*[local-name()='rect']").first as? XMLElement)
        let height = try #require(rect.attribute(forName: "height")?.stringValue.flatMap(Double.init))
        // A 10pt cmr10 hbox containing Hg has height 6.83331pt and depth 1.94444pt.
        #expect(abs(height / 1.24533 - (6 + 6.83331 + 1.94444)) < 0.5)
    }

    @Test("和文の三センチ枠は禁則と和欧間を保って五行になり、戻り罫を本文の外へ通す", .timeLimit(.minutes(1)))
    func japaneseBox() async throws {
        let source = #"""
            \documentclass[10pt]{ltjsreport}\usepackage{tikz}\usetikzlibrary{positioning}\begin{document}
            \begin{tikzpicture}
            \node[draw,text width=3cm,align=left] (a) {工程Aの記録を確認し、次の担当者へ渡す。作業リスト・チームを確認して保管する。};
            \node[draw,right=1cm of a] (b) {Return};
            \draw (b.south) |- (0,-3) -- (a.south);
            \end{tikzpicture}\end{document}
            """#
        let xml = try await render(source, theme: "latex-plain-ja")
        let nodes = try xml.nodes(forXPath: "//*[local-name()='text']").compactMap { $0 as? XMLElement }
        let glyphs = nodes.filter { $0.stringValue != "Return" }
        let lines = Dictionary(grouping: glyphs) { $0.attribute(forName: "y")?.stringValue.flatMap(Double.init) ?? 0 }
        let ys = lines.keys.sorted()
        #expect(ys.count == 5)
        let strings = ys.map { lines[$0, default: []].compactMap(\.stringValue).joined() }
        #expect(strings == ["工程Aの記録を確", "認し、次の担当者へ", "渡す。作業リスト・", "チームを確認して保", "管する。"])
        for (before, after) in zip(ys, ys.dropFirst()) {
            #expect(abs((after - before) / 1.24533 - 16) < 0.3)
        }
        let first = try #require(glyphs.first)
        func coordinate(_ item: XMLElement, _ key: String) throws -> Double {
            try #require(item.attribute(forName: key)?.stringValue.flatMap(Double.init))
        }
        let em = 10 * 1.24533
        let firstWidth = try coordinate(first, "textLength")
        #expect(abs(firstWidth / 2 / em - 0.924715) < 0.015)
        let latin = try #require(glyphs.first { $0.stringValue == "A" })
        let gap = try coordinate(latin, "x") - coordinate(first, "x") - firstWidth
        #expect(abs(gap / em - 0.25) < 0.05)
        let frame = try #require(xml.nodes(forXPath: "//*[local-name()='rect']").first as? XMLElement)
        let contentWidth = try coordinate(frame, "width") - 2 * 0.3333 * em
        for run in glyphs {
            let x = try coordinate(run, "x")
            let extent = try coordinate(run, "textLength")
            #expect(x >= -0.1)
            #expect(x + extent <= contentWidth + 0.1)
        }
        let height = try coordinate(frame, "height")
        #expect(abs(height / 1.24533 - (4 * 16 + 9.24713 + 6.666)) < 0.5)
        let path = try #require(xml.nodes(forXPath: "//*[local-name()='path' and @fill='none']").last as? XMLElement)
        let commands = try #require(path.attribute(forName: "d")?.stringValue)
        let coordinates = commands.split(whereSeparator: { $0 == "M" || $0 == "L" || $0 == " " }).compactMap {
            Double($0)
        }
        try #require(coordinates.count >= 6)
        #expect(coordinates[3] > height / 2)
        #expect(coordinates[4] == 0)
        #expect(coordinates[5] == coordinates[3])
    }

    private func render(_ latex: String, theme id: String) async throws -> XMLDocument {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == id })
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(latex.utf8), format: .latex),
            settings: RenderSettings(
                layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None")))
        let diagram = try #require(result.diagrams.first)
        return try XMLDocument(xmlString: diagram.svg, options: [])
    }
}
