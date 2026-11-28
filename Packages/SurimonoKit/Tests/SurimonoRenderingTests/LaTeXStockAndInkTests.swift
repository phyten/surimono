import AppKit
import CoreText
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXStockAndInkTests {
    @Test("同じ用紙では原寸を保ち、用紙が変わると本文寸法と両側の余白比を優先する")
    func paperChanges() {
        let centered = #"\documentclass[letterpaper]{article}\usepackage[total={112mm,165mm},centering]{geometry}"#
        let asymmetric =
            #"\documentclass[a4paper]{article}\usepackage[left=20mm,right=30mm,top=30mm,bottom=60mm]{geometry}"#
        let explicit = #"\documentclass[12pt,letterpaper]{article}\setlength{\textwidth}{96mm}"#
        let innerOuter =
            #"\documentclass[letterpaper,twoside]{article}\usepackage[inner=32mm,outer=19mm,top=22mm,bottom=26mm]{geometry}"#
        let proofSlip = #"\documentclass[letterpaper]{article}\usepackage[hmargin={22mm,40mm},vmargin=30mm]{geometry}"#
        // Expected left, right, top, bottom, text width and text height in millimetres.
        let cases: [(String, PaperSize, [Double])] = [
            (centered, .letter, [51.95, 51.95, 57.2, 57.2, 112, 165]),
            (innerOuter, .letter, [32, 19, 22, 26, 164.9, 231.4]),
            (proofSlip, .letter, [22, 40, 30, 30, 153.9, 219.4]),
            (centered, .a4, [49, 49, 66, 66, 112, 165]),
            (asymmetric, .letter, [22.36, 33.54, 24.1333, 48.2667, 160, 207]),
            (asymmetric, .a5, [0, 0, 1, 2, 148, 207]),
            (explicit, .a4, [37.1826, 76.8174, 53.3956, 50.8288, 96, 192.7757]),
        ]
        for (source, stock, expected) in cases {
            let box = LaTeXConverter.documentClassInfo(source + #"\begin{document}"#).pageBox
            let margins = box.margins(fitting: stock.size)
            let mm = 25.4 / 72
            let values = [
                margins.left, margins.right, margins.top, margins.bottom,
                stock.size.width * mm - margins.left - margins.right,
                stock.size.height * mm - margins.top - margins.bottom,
            ]
            for (actual, reference) in zip(values, expected) {
                #expect(abs(actual - reference) < 0.01)
            }
        }
    }

    @Test("通常の印刷と段組みのどちらも用紙変更後の本文幅と高さを使う", arguments: [true, false])
    func paginationMeasure(columns: Bool) async throws {
        let source =
            #"\documentclass[letterpaper]{article}\usepackage[total={112mm,165mm},centering]{geometry}\begin{document}"#
            + (columns ? #"\twocolumn"# : "") + #"\begin{lstlisting}[numbers=left,frame=single]"#
            + "\nA\n" + #"\end{lstlisting}\end{document}"#
        let renderer = DocumentRenderer(paginate: { request in
            #expect(request.latexFlow == columns)
            #expect(request.latexMarginInk)
            #expect(request.checksVerticalLaTeXInk)
            #expect(abs(request.pageSize.width - request.margins.left - request.margins.right - 317.4803) < 0.01)
            #expect(abs(request.pageSize.height - request.margins.top - request.margins.bottom - 467.7165) < 0.01)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        _ = try await renderer.prepare(DocumentSource(data: Data(source.utf8), format: .latex), settings: settings)
    }

    @Test("無装飾の単段本文は文書余白でも通常組版を保ち、余白を含む用紙幅で描ける")
    func plainUsesNative() async throws {
        let source = DocumentSource(
            data: Data(#"\documentclass[a4paper]{article}\begin{document}Plain.\end{document}"#.utf8), format: .latex)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        let renderer = DocumentRenderer(paginate: { request in
            #expect(!request.latexFlow)
            #expect(request.latexMarginInk && request.checksVerticalLaTeXInk)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        _ = try await renderer.prepare(source, settings: settings)
    }

    @Test("各段の先頭と末尾のインクだけが上下余白に達し、隣の切片は取り込まない")
    func verticalMarginInk() async throws {
        let pieces = [0, 25, 50].map { y in
            LaTeXFlowLayout.Piece(slice: .init(strip: y, start: 0, end: 25, width: 100), x: 0, y: CGFloat(y), scale: 1)
        }
        let edges = LaTeXFlowPaginator.verticalEdges(of: pieces, width: 100)
        #expect(edges.map(\.above) == [true, false, false])
        #expect(edges.map(\.below) == [false, false, true])
        let size = CGSize(width: 120, height: 100)
        let document = try await PDFDrawing.document(pageSize: size) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            for (piece, edge) in zip(pieces, edges) {
                let capture = LaTeXFlowPaginator.captureRects(
                    piece, origin: CGPoint(x: 40, y: 500), pageSize: size,
                    margins: .init(top: 20, left: 20, bottom: 20, right: 20), above: edge.above, below: edge.below)
                let slice = try await PDFDrawing.document(pageSize: capture.source.size) { sliceContext in
                    sliceContext.beginPDFPage(nil)
                    defer { sliceContext.endPDFPage() }
                    // Each strip paints above and below its layout box. Only the relevant edge
                    // survives its viewport; no replica of the middle strip's marks may reach the page.
                    for y in [CGFloat(495), 534] {
                        sliceContext.fill(
                            CGRect(x: 50 - capture.source.minX, y: capture.source.maxY - y - 2, width: 5, height: 4))
                    }
                }
                try FlowPageCapture.draw(try #require(slice.dataRepresentation()), into: capture.target, in: context)
            }
        }
        let page = try #require(document.page(at: 0))
        #expect(try RenderingFixtures.pixel(page, x: 30, y: 84)[0] < 100)
        #expect(try RenderingFixtures.pixel(page, x: 30, y: 13)[0] < 100)
        #expect(try RenderingFixtures.pixel(page, x: 30, y: 64)[0] > 240)
        #expect(try RenderingFixtures.pixel(page, x: 30, y: 33)[0] > 240)
    }

    @Test("2 段組の内側の切片は、段の間より外へ出た行番号のインクも段の間の向こうまで取り込む")
    func innerColumnInk() {
        // A4-like measure in print pixels: two 140-pixel columns with a 20-pixel gutter.
        let margins = WebPaginator.Margins(top: 20, left: 20, bottom: 20, right: 20)
        let pageSize = CGSize(width: 300 / WebPaginator.printPixelsPerPoint + 40, height: 400)
        let right = LaTeXFlowLayout.Piece(slice: .init(strip: 0, start: 0, end: 50, width: 140), x: 160, y: 0, scale: 1)
        let left = LaTeXFlowLayout.Piece(slice: .init(strip: 0, start: 0, end: 50, width: 140), x: 0, y: 0, scale: 1)
        let origin = CGPoint(x: 400, y: 0)
        // listings puts numbers numbersep (10pt) plus their own width left of the code: beyond half the gutter.
        let rightCapture = LaTeXFlowPaginator.captureRects(right, origin: origin, pageSize: pageSize, margins: margins)
        #expect(rightCapture.source.minX <= origin.x - 30)
        let leftCapture = LaTeXFlowPaginator.captureRects(left, origin: origin, pageSize: pageSize, margins: margins)
        #expect(leftCapture.source.maxX >= origin.x + 140 + 30)
    }

    @Test("切片の外の番号と端にまたがるベクトル罫が同じ縮尺・位置で PDF に載る")
    func captureInk() async throws {
        let piece = LaTeXFlowLayout.Piece(
            slice: .init(strip: 0, start: 5.25, end: 30.5, width: 112.5), x: 0, y: 12.5, scale: 1)
        let capture = LaTeXFlowPaginator.captureRects(
            piece, origin: CGPoint(x: 27.25, y: 5.5), pageSize: CGSize(width: 140, height: 120),
            margins: .init(top: 20, left: 20, bottom: 20, right: 30))
        #expect(capture.source == CGRect(x: 1, y: 9, width: 178, height: 28))
        #expect(abs(capture.target.minX + 1) < 0.001)
        // The viewport starts at a fractional coordinate. Model the resulting strip in CSS pixels,
        // then pass it through the same PDF drawing transform as an actual WKPDFConfiguration capture.
        let sliced = try await PDFDrawing.document(pageSize: capture.source.size) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            let left = 27.25 - capture.source.minX
            let bottom = capture.source.maxY - 36
            let label = NSAttributedString(string: "7", attributes: [.font: NSFont.systemFont(ofSize: 8)])
            context.textPosition = CGPoint(x: left - 13, y: bottom + 10)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(1.25)
            context.stroke(CGRect(x: left, y: bottom, width: 112.5, height: 25.25))
        }
        let data = try #require(sliced.dataRepresentation())
        let output = try await PDFDrawing.document(pageSize: CGSize(width: 140, height: 120)) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            try FlowPageCapture.draw(data, into: capture.target, in: context)
        }
        let page = try #require(output.page(at: 0))
        let label = try #require(output.findString("7").first)
        #expect(label.bounds(for: page).maxX < 20)
        #expect(try RenderingFixtures.pixel(page, x: 110, y: 80)[0] < 200)
        #expect(try RenderingFixtures.pixel(page, x: 60, y: 70)[0] < 200)
    }
}
