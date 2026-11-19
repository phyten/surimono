import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing

@testable import SurimonoRendering

@MainActor
struct LaTeXFancyFurnitureTests {
    @Test("左右のヘッダーと中央の番号を読む PDF と用紙 PDF の同じ位置に描く")
    func exportedPages() async throws {
        let source = DocumentSource(
            data: Data(
                #"""
                \documentclass{article}\usepackage[left=60bp,right=90bp,top=95bp,bottom=75bp,headsep=21bp,footskip=28bp]{geometry}
                \fancypagestyle{workshop}{\fancyhf{}\lhead{Workshop}\rhead{Crew sheet}\cfoot{Page \thepage}}\pagestyle{workshop}
                \begin{document}Body\end{document}
                """#.utf8), format: .latex)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            WebPaginator.Result(document: try RenderingFixtures.pdf(count: 2, size: request.pageSize))
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let settings = RenderSettings(layout: .letterSingle, theme: theme, preset: .init(id: "none", name: ""))
        let prepared = try await renderer.prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Sample", furniture: prepared.viewFurniture)
        let sheets = try await renderer.composeSheet(for: prepared)
        for pdf in [reading, sheets.sheetDocument] {
            let second = try #require(pdf.page(at: 1))
            let left = try #require(pdf.findString("Workshop").first { $0.pages.first === second })
            let right = try #require(pdf.findString("Crew sheet").first { $0.pages.first === second })
            let foot = try #require(pdf.findString("Page 2").first { $0.pages.first === second })
            let bounds = second.bounds(for: .mediaBox)
            #expect(abs(left.bounds(for: second).minX - 60) < 2)
            #expect(abs(right.bounds(for: second).maxX - (bounds.width - 90)) < 2)
            #expect(left.bounds(for: second).contains(CGPoint(x: 62, y: bounds.height - 74)))
            #expect(foot.bounds(for: second).contains(CGPoint(x: (bounds.width - 30) / 2, y: 47)))
        }
    }

    @Test("論文クラスが番号を抑止するページでも利用者が選んだ柱を両方の PDF に出す")
    func customFurniture() async throws {
        let source = DocumentSource(
            data: Data(#"\documentclass[conference]{IEEEtran}\begin{document}Text\end{document}"#.utf8), format: .latex)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            WebPaginator.Result(document: try RenderingFixtures.pdf(count: 1, size: request.pageSize))
        })
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var options = PrintOptions()
        options.furniture.topRight = "Review copy"
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""), options: options)
        let prepared = try await renderer.prepare(source, settings: settings)
        let reading = try ReadingPDFExporter.document(
            from: prepared.viewDocument, entries: [], title: "Sample", furniture: prepared.viewFurniture)
        let sheet = try await renderer.composeSheet(for: prepared)
        #expect(prepared.viewFurniture[0]?.latexFooter == nil)
        #expect(reading.findString("Review copy").count == 1)
        #expect(sheet.sheetDocument.findString("Review copy").count == 1)
    }

    @Test("柱の罫だけのページにも既定の〇・四ポイントを引き、指定したページだけ罫を切り替える")
    func fancyRules() {
        let state = LaTeXConverter.documentClassInfo(
            #"\documentclass{article}\pagestyle{fancy}\fancyhf{}\fancypagestyle{lined}{\renewcommand{\headrulewidth}{0pt}\renewcommand{\footrulewidth}{1bp}}"#
        ).pageNumbers
        let map = LaTeXPageReferences.map(
            state,
            targets: [
                .init(action: "thispagestyle", value: "lined", referenced: false),
                .init(action: "thispagestyle", value: "plain", referenced: false),
            ],
            locations: [0: 1, 1: 2], pageCount: 4, restartsAfterTitle: false)
        #expect(abs(map.pages[0].lines.headRule - 0.3985) < 0.001)
        #expect(!map.pages[0].lines.isEmpty)
        #expect(map.pages[1].lines.headRule == 0)
        #expect(abs(map.pages[1].lines.footRule - 1) < 0.001)
        #expect(map.pages[2].lines.headRule == 0)
        #expect(map.pages[3].lines == map.pages[0].lines)
    }

    @Test("文字のない柱と脚の罫も本文幅の両端まで描く", arguments: [true, false])
    func ruleInk(header: Bool) async throws {
        let size = CGSize(width: 180, height: 220)
        let pdf = try await PDFDrawing.document(pageSize: size) { context in
            var lines = PageFurniture.Lines(top: ["", "", ""], bottom: ["", "", ""])
            if header { lines.headRule = 2 } else { lines.footRule = 2 }
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            PageFurnitureDrawing.draw(
                lines, in: CGRect(origin: .zero, size: size), margins: .init(top: 42, left: 24, bottom: 40, right: 16),
                scale: 1, latexFooter: .init(fontName: nil, pointSize: 10, footSkip: 20, headSep: 18), context: context)
        }
        let page = try #require(pdf.page(at: 0))
        #expect(try RenderingFixtures.inkColumns(page) == 24...163)
        let ys = header ? 187...197 : 27...38
        #expect(try ys.contains { try RenderingFixtures.pixel(page, x: 90, y: $0)[0] < 150 })
    }

    @Test("柱罫は原寸で〇・四 TeX ポイントの黒い実線になる")
    func defaultRuleWidth() async throws {
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 60, height: 60)) { context in
            var lines = PageFurniture.Lines(top: ["", "", ""], bottom: ["", "", ""])
            let style = LaTeXConverter.documentClassInfo(#"\documentclass{article}\pagestyle{fancy}"#)
            lines.headRule = style.pageNumbers.ruleWidth("headrulewidth")
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            PageFurnitureDrawing.draw(
                lines, in: CGRect(x: 0, y: 0, width: 60, height: 60), margins: .uniform(millimeters: 5),
                scale: 1, context: context)
        }
        // Sample one vertical strip at high resolution so pixel alignment cannot hide a thin rule.
        let scale = 32
        let height = 60 * scale
        let raster = try #require(
            CGContext(
                data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        raster.setFillColor(gray: 1, alpha: 1)
        raster.fill(CGRect(x: 0, y: 0, width: 1, height: height))
        raster.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        raster.translateBy(x: -30, y: 0)
        raster.drawPDFPage(try #require(pdf.page(at: 0)?.pageRef))
        let pixels = UnsafeBufferPointer(
            start: try #require(raster.data).assumingMemoryBound(to: UInt8.self), count: height)
        #expect(pixels.min() == 0)
        let ink = pixels.reduce(0.0) { $0 + 1 - Double($1) / 255 } / Double(scale)
        #expect(abs(ink - 0.3985) < 0.035)
    }

    @Test("三ページとメモの柱罫と脚罫は原稿の枠の外に置く")
    func handoutRules() async throws {
        let rect = CGRect(x: 24, y: 40, width: 140, height: 120)
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 180, height: 220)) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            for above in [true, false] {
                PageFurnitureDrawing.drawHandoutRow(
                    ["", "", ""], beside: rect, above: above, space: 20, padding: 1, rule: 2, context: context)
            }
        }
        let page = try #require(pdf.page(at: 0))
        #expect(try RenderingFixtures.inkColumns(page) == 24...163)
        for y in [38, 160] {
            #expect(try RenderingFixtures.pixel(page, x: 90, y: y)[0] < 150)
        }
    }

    @Test("柱の左はそのページの最後の見出し、右は最初の印を取り次ページへ引き継ぐ")
    func runningMarks() {
        let state = LaTeXConverter.documentClassInfo(
            #"\documentclass{article}\pagestyle{fancy}\fancyhf{}\lhead{\leftmark}\rhead{\rightmark}"#
        ).pageNumbers
        let targets: [LaTeXPageReferences.Target] = [
            .init(action: "majorMark", value: "1 WORKSHOP", referenced: false),
            .init(action: "rightmark", value: "1.1 Crew", referenced: false),
            .init(action: "rightmark", value: "1.2 Stock", referenced: false),
            .init(action: "rightmark", value: "1.3 Spares", referenced: false),
            .init(action: "thispagestyle", value: "empty", referenced: false),
        ]
        let map = LaTeXPageReferences.map(
            state, targets: targets, locations: [0: 0, 1: 0, 2: 1, 3: 1, 4: 3], pageCount: 4, restartsAfterTitle: false)
        #expect(
            map.pages.map(\.lines.top) == [
                ["1 WORKSHOP", "", ""], ["1 WORKSHOP", "", "1.2 Stock"], ["1 WORKSHOP", "", "1.3 Spares"],
                ["", "", ""],
            ])
    }
}
