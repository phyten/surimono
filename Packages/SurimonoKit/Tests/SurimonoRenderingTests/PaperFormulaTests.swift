import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PaperFormulaTests {
    private func render(_ text: String, format: DocumentFormat) async throws -> PreparedRender {
        _ = NSApplication.shared
        let renderer = DocumentRenderer()
        let source = DocumentSource(data: Data(text.utf8), format: format)
        let themes = try PrintThemeLibrary.load()
        let theme = try #require(themes.first { $0.id == (format == .latex ? "latex-article" : "standard") })
        return try await renderer.prepare(
            source, settings: .init(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
    }

    @Test("段組みの列と数式の位置が一致し、環境とマクロの原文を取り出せる", .timeLimit(.minutes(1)))
    func columns() async throws {
        let text = #"""
            \documentclass[twocolumn]{article}
            \usepackage{amsmath}
            \newcommand{\leaf}{z}
            \begin{document}
            Left $\leaf$.
            \newpage
            Right $Q$.
            \begin{align}x &= 7\label{first}\\y &= 8\end{align}
            \[\begin{cases}a & b\\c & d\end{cases}\]
            \end{document}
            """#
        let paper = try await render(text, format: .latex)
        let index = try #require(paper.formulaIndex)
        #expect(index.entries == nil)
        let entries = try await index.resolve()
        let page = try #require(paper.viewDocument.page(at: 0))
        for (source, text) in [
            (#"\leaf"#, "z"), ("Q", "Q"), (#"\begin{align}x &= 7\label{first}\\y &= 8\end{align}"#, "7"),
            (#"\begin{cases}a & b\\c & d\end{cases}"#, "d"),
        ] {
            let entry = try #require(entries.first { $0.formulaSource == source })
            #expect(entry.pageIndex == 0)
            let selections = paper.viewDocument.findString(text, withOptions: [])
            #expect(
                selections.contains {
                    $0.pages.contains(page)
                        && entry.rect.contains(CGPoint(x: $0.bounds(for: page).midX, y: $0.bounds(for: page).midY))
                })
        }
        #expect(entries.count == 4)
        let left = try #require(entries.first { $0.formulaSource == #"\leaf"# })
        let right = try #require(entries.first { $0.formulaSource == "Q" })
        #expect(right.rect.midX - left.rect.midX > 100)
        #expect(page.annotations.allSatisfy { $0.url?.scheme != "surimono-diagram" })
    }

    @Test("本文と別行の数式を独立した書体付きSVGと白い余白のあるPNGにできる", .timeLimit(.minutes(1)))
    func standalone() async throws {
        let paper = try await render(
            #"""
            A [$x^2$](https://example.org/) here.

            \[\frac{A}{B}\]
            """#, format: .markdown)
        let index = try #require(paper.formulaIndex)
        let entries = try await index.resolve()
        #expect(entries.map(\.formulaSource) == ["x^2", #"\frac{A}{B}"#])
        let page = try #require(paper.viewDocument.page(at: 0))
        for (entry, glyph) in zip(entries, ["x", "B"]) {
            let selection = try #require(paper.viewDocument.findString(glyph, withOptions: []).first)
            let r = selection.bounds(for: page)
            let point = CGPoint(x: r.midX, y: r.midY)
            #expect(entry.rect.contains(point))
            if glyph == "x" {
                #expect(page.annotations.contains { $0.url?.host == "example.org" && $0.bounds.contains(point) })
            }
            let svg = WebPaginator.exportSVG(entry)
            let xml = try XMLDocument(xmlString: svg, options: [])
            let root = try #require(xml.rootElement())
            #expect(root.attribute(forName: "viewBox") != nil)
            #expect(root.elements(forName: "rect").first?.attribute(forName: "fill")?.stringValue == "white")
            #expect(root.elements(forName: "title").first?.stringValue == entry.formulaSource)
            #expect(!root.elements(forName: "text").isEmpty)
            #expect(try xml.nodes(forXPath: "//@href").isEmpty)
            let rules = try #require(root.elements(forName: "style").first?.stringValue)
            #expect(rules.components(separatedBy: "data:font/otf;base64,").count - 1 == (glyph == "x" ? 2 : 1))
            let png = try await WebPaginator.diagramPNG(entry)
            let image = try #require(NSBitmapImageRep(data: png))
            #expect(image.pixelsHigh >= 96)
            var ink = CGRect.null
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.redComponent < 0.8 { ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1)) }
                }
            }
            let reference = try printedInk(page, in: entry.rect)
            let ratio = Double(image.pixelsWide) / entry.pointSize.width
            let geometry =
                "\(glyph) PNG=\(image.pixelsWide)×\(image.pixelsHigh) ink=\(ink) px、倍率=\(ratio)、PDF ink=\(reference) pt、範囲=\(entry.rect)、SVG=\(entry.pointSize)"
            #expect(abs(ink.width / ratio - reference.width) < 0.65, "\(geometry)")
            #expect(abs(ink.height / ratio - reference.height) < 0.65, "\(geometry)")
            #expect(!ink.isNull)
            #expect(ink.minX >= 1 && ink.maxX < CGFloat(image.pixelsWide))
            #expect(ink.minY >= 1 && ink.maxY < CGFloat(image.pixelsHigh))
        }
    }
    @Test(
        "各形式の数式を同じ索引から取り出せる", .timeLimit(.minutes(1)),
        arguments: [
            DocumentFormat.org, .rst, .asciidoc, .djot, .mediawiki, .quarto, .rMarkdown, .notebook,
        ])
    func otherFormats(format: DocumentFormat) async throws {
        let source: String =
            switch format {
            case .rst: "Inside :math:`x^2` here."
            case .asciidoc: ":stem: latexmath\n\nInside stem:[x^2] here."
            case .djot: "Inside $`x^2` here."
            case .mediawiki: "Inside <math>x^2</math> here."
            case .notebook:
                #"{"cells":[{"cell_type":"markdown","metadata":{},"source":["Inside $x^2$ here."]}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#
            default: "Inside $x^2$ here."
            }
        let paper = try await render(source, format: format)
        let index = try #require(paper.formulaIndex)
        let entries = try await index.resolve()
        #expect(entries.map(\.formulaSource) == ["x^2"])
    }

    private func printedInk(_ page: PDFPage, in rect: CGRect) throws -> CGSize {
        let scale = 8.0
        let w = Int(ceil(rect.width * scale))
        let h = Int(ceil(rect.height * scale))
        let bitmap = try #require(
            CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -rect.minX, y: -rect.minY)
        bitmap.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var ink = CGRect.null
        for y in 0..<h {
            for x in 0..<w where bytes[y * w + x] < 204 {
                ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CGSize(width: ink.width / scale, height: ink.height / scale)
    }

    @Test("数式内のタグは原文に残し、保存する字形からは外す", .timeLimit(.minutes(1)))
    func embeddedTags() async throws {
        let paper = try await render(
            #"""
            \[x=3\tag{NOTE}\]

            \[\begin{align}a&=b\\c&=d\end{align}\]
            """#, format: .markdown)
        let index = try #require(paper.formulaIndex)
        let entries = try await index.resolve()
        try #require(entries.count == 2)
        for (entry, expected) in zip(entries, ["x=3", "a=bc=d"]) {
            let root = try #require(try XMLDocument(xmlString: WebPaginator.exportSVG(entry)).rootElement())
            #expect(root.elements(forName: "text").compactMap(\.stringValue).joined() == expected)
        }
        #expect(entries[0].formulaSource == #"x=3\tag{NOTE}"#)
    }

    @Test("本文幅に別々に揃えた数式の行も全体を一つの式として取り出す", .timeLimit(.minutes(1)))
    func multiline() async throws {
        let source = #"\begin{multline}a+b\\=c\label{sum}\end{multline}"#
        let paper = try await render(
            "\\documentclass{article}\\begin{document}\(source)\\end{document}", format: .latex)
        let index = try #require(paper.formulaIndex)
        let entries = try await index.resolve()
        try #require(entries.count == 1)
        let entry = entries[0]
        #expect(entry.formulaSource == source)
        let root = try #require(try XMLDocument(xmlString: WebPaginator.exportSVG(entry)).rootElement())
        #expect(root.elements(forName: "text").compactMap(\.stringValue).joined() == "a+b=c")
        let page = try #require(paper.viewDocument.page(at: entry.pageIndex))
        for glyph in ["a", "c", "(1)"] {
            let bounds = try #require(paper.viewDocument.findString(glyph, withOptions: []).first).bounds(for: page)
            #expect(entry.rect.contains(CGPoint(x: bounds.midX, y: bounds.midY)) == (glyph != "(1)"))
        }
    }

    @Test("数式モードの囲みだけを外し、背の高い行列は紙面の三倍で書き出す", .timeLimit(.minutes(1)))
    func mathMode() async throws {
        let matrix = #"\begin{matrix}1\\2\\3\\4\\5\end{matrix}"#
        let paper = try await render(
            """
            \\documentclass{article}\\begin{document}
            Inline \\begin{math}a+b\\end{math}.
            \\begin{displaymath}\(matrix)\\end{displaymath}
            \\end{document}
            """, format: .latex)
        let index = try #require(paper.formulaIndex)
        let entries = try await index.resolve()
        #expect(entries.map(\.formulaSource) == ["a+b", matrix])
        let entry = try #require(entries.last)
        try #require(entry.pointSize.height > 32)
        let bytes = try await WebPaginator.diagramPNG(entry)
        let image = try #require(NSBitmapImageRep(data: bytes))
        #expect(image.pixelsHigh == Int((entry.pointSize.height * 3).rounded()))
        #expect(image.pixelsWide == Int((entry.pointSize.width * 3).rounded()))
    }
}
