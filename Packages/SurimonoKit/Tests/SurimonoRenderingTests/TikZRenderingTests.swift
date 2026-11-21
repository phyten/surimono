import AppKit
import Foundation
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct TikZRenderingTests {
    @Test("実測した二つの箱の縁に外余白を加えて一センチ離し、紙の一つの図として保存する", .timeLimit(.minutes(1)))
    func measuredNodes() async throws {
        _ = NSApplication.shared
        let source = #"""
            \documentclass{article}
            \begin{document}
            \begin{tikzpicture}[every node/.style={draw,inner sep=3pt,outer sep=1pt}]
            \node (a) {Wide label};
            \node[right=1cm of a] (b) {\textbf{B}};
            \draw[->] (a.east) -- (b.west);
            \end{tikzpicture}
            \end{document}
            """#
        let result = try await render(source)
        #expect(result.diagrams.count == 1)
        let diagram = try #require(result.diagrams.first)
        let xml = try XMLDocument(xmlString: diagram.svg, options: [])
        let boxes = try xml.nodes(forXPath: "//*[local-name()='rect']").compactMap { $0 as? XMLElement }
        try #require(boxes.count == 2)
        func origin(_ rect: XMLElement) throws -> Double {
            let transform = try #require((rect.parent as? XMLElement)?.attribute(forName: "transform")?.stringValue)
            let first = try #require(transform.split(whereSeparator: { $0 == "(" || $0 == " " }).dropFirst().first)
            return try #require(Double(first))
        }
        func width(_ rect: XMLElement) throws -> Double {
            try #require(rect.attribute(forName: "width")?.stringValue.flatMap(Double.init))
        }
        let east = try origin(boxes[0]) + width(boxes[0]) / 2
        let west = try origin(boxes[1]) - width(boxes[1]) / 2
        // One cm between border anchors; each anchor includes the explicitly requested outer sep.
        #expect(abs((west - east) - 40.45) < 0.1)
        #expect(!diagram.svg.contains("foreignObject"))
        #expect(!diagram.svg.contains("<image"))
        let runs = try xml.nodes(forXPath: "//*[local-name()='text']").compactMap { $0 as? XMLElement }
        #expect(runs.count == 2)
        for run in runs {
            let advance = try #require(run.attribute(forName: "textLength")?.stringValue.flatMap(Double.init))
            #expect(advance > 0)
            #expect(run.attribute(forName: "lengthAdjust")?.stringValue == "spacingAndGlyphs")
        }
        let page = try #require(result.viewDocument.page(at: diagram.pageIndex))
        #expect(page.selection(for: diagram.rect)?.string?.contains("Wide label") == true)
        #expect(page.bounds(for: .mediaBox).contains(diagram.rect))
    }

    @Test("数式ラベルの字形と書体をSVGに含め、未対応命令がある別の図は丸ごと紙の注記になる", .timeLimit(.minutes(1)))
    func mathAndFallback() async throws {
        _ = NSApplication.shared
        let source = #"""
            \documentclass{article}
            \begin{document}
            \begin{tikzpicture}\draw (0,0) -- (1,1) node[right] {$x^2$};\end{tikzpicture}
            \begin{tikzpicture}\node {NeverPaint};\matrix {A};\end{tikzpicture}
            \end{document}
            """#
        let result = try await render(source)
        #expect(result.diagrams.count == 1)
        let diagram = try #require(result.diagrams.first)
        #expect(diagram.svg.contains("KaTeX_"))
        #expect(diagram.svg.contains("data:font/otf;base64,"))
        #expect(!diagram.svg.contains("foreignObject"))
        #expect(result.viewDocument.string?.contains("Figure (TikZ)") == true)
        #expect(result.viewDocument.string?.contains("NeverPaint") == false)
    }

    @Test("article の用紙に刷ったグラフの横幅が参照 PDF の軸枠に合う", .timeLimit(.minutes(1)))
    func articleAxisWidth() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let source = #"""
            \documentclass{article}\usepackage{pgfplots}\begin{document}
            \begin{tikzpicture}\begin{axis}[xlabel=Station,ylabel={Head (mm)},grid=major]
            \addplot coordinates {(0,8)(1,7)(2,5)(3,4)};
            \end{axis}\end{tikzpicture}\end{document}
            """#
        let result = try await render(source, theme: theme)
        let diagram = try #require(result.diagrams.first)
        let xml = try XMLDocument(xmlString: diagram.svg, options: [])
        let paths = try xml.nodes(forXPath: "//*[local-name()='path' and @stroke='#000000']")
        let rectangles = paths.compactMap { ($0 as? XMLElement)?.attribute(forName: "d")?.stringValue }
            .filter { $0.hasPrefix("M0 0 L") && $0.hasSuffix(" Z") }
        let commands = try #require(rectangles.first)
        let x = try #require(commands.split(separator: " ").dropFirst(2).first?.dropFirst())
        let axisWidth = try #require(Double(x))
        let viewBox = try #require(xml.rootElement()?.attribute(forName: "viewBox")?.stringValue)
        let svgWidth = try #require(viewBox.split(separator: " ").dropFirst(2).first.flatMap { Double($0) })
        // Corpus 073's reference PDF has its axis border at x=-16.188469 and x=178.081063 pt.
        #expect(abs(diagram.pointSize.width * axisWidth / svgWidth - 194.27) < 3)
    }

    private func render(
        _ latex: String, theme: PrintTheme = PrintTheme(id: "test", name: "Test", css: "body { font: 12pt serif; }")
    ) async throws -> PreparedRender {
        try await DocumentRenderer().prepare(
            DocumentSource(data: Data(latex.utf8), format: .latex),
            settings: RenderSettings(
                layout: .a4Single, theme: theme,
                preset: HTMLCleanupPreset(id: "none", name: "None")))
    }
}

extension TikZRenderingTests {
    @Test("行列の外枠間に列六ミリ・行五ミリを取り、中央列の上下のセルを矢印で結ぶ", .timeLimit(.minutes(1)))
    func matrixSpacingAndConnector() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let result = try await render(
            #"""
            \documentclass{article}\usepackage{tikz}\usetikzlibrary{matrix,arrows.meta}
            \begin{document}\begin{tikzpicture}
            \matrix (m)[matrix of nodes,nodes={draw,minimum width=15mm},row sep=5mm,column sep=6mm]
              {A1 & A2 & A3 \\ B1 & B2 & B3 \\};
            \draw[-{Stealth},blue] (m-1-2)--(m-2-2);
            \end{tikzpicture}\end{document}
            """#, theme: theme)
        let diagram = try #require(result.diagrams.first)
        let xml = try XMLDocument(xmlString: diagram.svg, options: [])
        let viewBox = try #require(xml.rootElement()?.attribute(forName: "viewBox")?.stringValue)
        let width = try #require(viewBox.split(separator: " ").dropFirst(2).first.flatMap { Double($0) })
        let scale = diagram.pointSize.width / width
        let rects = try xml.nodes(forXPath: "//*[local-name()='rect' and @stroke='#000000']").compactMap {
            $0 as? XMLElement
        }
        try #require(rects.count == 6)
        func origin(_ rect: XMLElement) throws -> CGPoint {
            let transform = try #require((rect.parent as? XMLElement)?.attribute(forName: "transform")?.stringValue)
            let values = transform.split(whereSeparator: { $0 == "(" || $0 == ")" || $0 == " " }).compactMap {
                Double($0)
            }
            try #require(values.count >= 2)
            return CGPoint(x: values[0], y: values[1])
        }
        let left = try origin(rects[0])
        let upper = try origin(rects[1])
        let lower = try origin(rects[4])
        let cellWidth = try #require(rects[1].attribute(forName: "width")?.stringValue.flatMap(Double.init))
        let cellHeight = try #require(rects[1].attribute(forName: "height")?.stringValue.flatMap(Double.init))
        let stroke = try #require(rects[1].attribute(forName: "stroke-width")?.stringValue.flatMap(Double.init))
        #expect(abs(cellWidth * scale - 42.52) < 1)
        #expect(abs((upper.x - left.x - cellWidth - stroke) * scale - 17.01) < 1)
        #expect(abs((lower.y - upper.y - cellHeight - stroke) * scale - 14.17) < 1)
        let connector = try #require(
            xml.nodes(forXPath: "//*[local-name()='path' and @marker-end and @stroke='#0000ff']").first as? XMLElement)
        let commands = try #require(connector.attribute(forName: "d")?.stringValue)
        let ends = commands.split(whereSeparator: { "ML ,".contains($0) }).compactMap { Double($0) }
        try #require(ends.count == 4)
        #expect(abs(ends[0] - upper.x) < 0.1 && abs(ends[2] - lower.x) < 0.1)
        #expect(ends[1] > upper.y && ends[1] < ends[3] && ends[3] < lower.y)
    }
}
