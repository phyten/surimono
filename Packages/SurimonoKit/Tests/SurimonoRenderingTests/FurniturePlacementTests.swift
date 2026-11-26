import AppKit
import CoreText
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// What the sheets draw where on a logical page, and the view mode's paper that shows the same.
@MainActor
struct FurniturePlacementTests {
    private func points(_ millimeters: Double) -> CGFloat { CGFloat(millimeters * 72 / 25.4) }

    private func sides() -> PageFurniture {
        var furniture = PageFurniture()
        furniture.topLeft = "左"
        furniture.topRight = "右"
        furniture.swapsOnSpreads = true
        return furniture
    }

    @Test("ファイル名と番号の型は片面の A4 の 3 ページ目の上にファイル名、下に「3 / 9」を、余白の中に置く")
    func pageNumberPreset() throws {
        var options = PrintOptions()
        options.furniture = .name
        let context = PageFurniture.Context(fileName: "memo.md")
        let placement = try #require(
            PDFComposer.furniture(
                onPage: 2, at: 2, pageCount: 9, layout: .a4Single, options: options, context: context))
        #expect(placement.lines.top == ["memo.md", "", ""])
        #expect(placement.lines.bottom == ["", "3 / 9", ""])
        #expect(abs(placement.pageSize.width - 595.28) < 0.01)
        #expect(abs(placement.pageSize.height - 841.89) < 0.01)
        #expect(abs(placement.margins.top - points(15)) < 0.01)
        #expect(abs(placement.margins.bottom - points(15)) < 0.01)
    }

    @Test("1 ページ目を除く設定では 1 ページ目に何も置かず、2 ページ目から置く")
    func skipsFirstPage() {
        var options = PrintOptions()
        options.furniture = .pageNumber
        options.furniture.skipsFirstPage = true
        #expect(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 3, layout: .a4Single, options: options, context: .init()) == nil)
        #expect(
            PDFComposer.furniture(
                onPage: 1, at: 1, pageCount: 3, layout: .a4Single, options: options, context: .init())?.lines.bottom
                == ["", "2", ""])
    }

    @Test("見開きで入れ替える設定は左とじの偶数ページと右とじの奇数ページで左右を入れ替える")
    func swapsOnSpreads() {
        var options = PrintOptions()
        options.furniture = sides()
        func top(_ index: Int, _ layout: PrintLayout) -> [String]? {
            PDFComposer.furniture(
                onPage: index, at: index, pageCount: 4, layout: layout, options: options, context: .init())?.lines.top
        }
        #expect(top(0, .a4Duplex) == ["左", "", "右"])
        #expect(top(1, .a4Duplex) == ["右", "", "左"])
        #expect(top(0, PrintLayout.a4BookletA5.bound(.right)) == ["右", "", "左"])
        #expect(top(1, PrintLayout.a4BookletA5.bound(.right)) == ["左", "", "右"])
        // Single-sided sheets have no spreads to swap on.
        #expect(top(1, .a4Single) == ["左", "", "右"])
    }

    @Test("右ページ始まりで足した白紙には何も置かず、内外の余白は裏のページで入れ替える")
    func blankPagesAndMirroredMargins() throws {
        var options = PrintOptions()
        options.furniture = .pageNumber
        options.margins = PageMargins(top: 15, left: 20, bottom: 15, right: 10)
        options.mirrorsMargins = true
        let context = PageFurniture.Context(blankPages: [2])
        #expect(
            PDFComposer.furniture(onPage: 2, at: 2, pageCount: 4, layout: .a4Duplex, options: options, context: context)
                == nil)
        let front = try #require(
            PDFComposer.furniture(onPage: 0, at: 0, pageCount: 4, layout: .a4Duplex, options: options, context: context)
        )
        let back = try #require(
            PDFComposer.furniture(onPage: 1, at: 1, pageCount: 4, layout: .a4Duplex, options: options, context: context)
        )
        #expect(abs(front.margins.left - points(20)) < 0.01)
        #expect(abs(back.margins.left - points(10)) < 0.01)
    }

    @Test("3 ページ＋メモではページの外に置くので、ページの上には何も置かない")
    func handoutHasNothingOnThePage() {
        var options = PrintOptions()
        options.furniture = .pageNumber
        #expect(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 3, layout: .a4Handout3, options: options, context: .init()) == nil)
    }

    /// A logical page of A4 with its body text in the middle, as the paginator would make it.
    private func bodyPage() throws -> PDFDocument {
        let size = PrintLayout.a4Single.logicalPageSize(options: PrintOptions())
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let text = NSAttributedString(string: "BODYTEXT", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        context.textPosition = CGPoint(x: 100, y: size.height / 2)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    /// Whether anything darker than the paper is drawn in the top margin of a page.
    private func hasInkInTopMargin(_ page: PDFPage) throws -> Bool {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let margin = Int(points(15))
        // Rows from the top of the bitmap, which is the top of the page.
        return (0..<margin).contains { y in (0..<width).contains { x in bytes[(y * width + x) * 4] < 160 } }
    }

    @Test("表示の紙は刷るときのヘッダーを描き、ページの文字は本文だけで一度ずつ探せる")
    func viewPageShowsFurnitureAndKeepsItsText() throws {
        let source = try bodyPage()
        var options = PrintOptions()
        options.furniture = .name
        let placement = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 1, layout: .a4Single, options: options,
                context: PageFurniture.Context(fileName: "HEADERNAME.md")))
        let plan = ViewPageLayout(
            pageCount: 1,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: true, showsNumbers: false)
        let bare = try #require(ViewPageDocument.make(source, plan: plan, margin: points(15)))
        let decorated = try #require(
            ViewPageDocument.make(source, plan: plan, margin: points(15), furniture: [0: placement]))
        let page = try #require(decorated.page(at: 0))
        #expect(try !hasInkInTopMargin(try #require(bare.page(at: 0))))
        #expect(try hasInkInTopMargin(page))
        #expect(page.string?.components(separatedBy: "BODYTEXT").count == 2)
        #expect(page.string?.contains("HEADERNAME") == false)
        #expect(decorated.findString("BODYTEXT", withOptions: []).count == 1)
        #expect(decorated.findString("HEADERNAME", withOptions: []).isEmpty)
    }

    @Test("ヘッダーとフッターだけを変えても組版し直さず、表示の紙に描くものだけが変わる")
    func furnitureChangeDoesNotPaginate() async throws {
        final class Counter { var calls = 0 }
        let counter = Counter()
        let renderer = DocumentRenderer(paginate: { request in
            counter.calls += 1
            return try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let themes = try PrintThemeLibrary.load()
        var settings = RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.documentName = "memo.md"
        let source = DocumentSource(data: Data("# 一\n\n本文\n".utf8), format: .markdown)
        let plain = try await renderer.prepare(source, settings: settings)
        #expect(plain.viewFurniture.isEmpty)
        settings.options.furniture = .name
        let named = try await renderer.prepare(source, settings: settings)
        #expect(counter.calls == 1)
        #expect(named.logicalDocument === plain.logicalDocument)
        #expect(named.viewFurniture[0]?.lines.top == ["memo.md", "", ""])
        #expect(named.viewFurniture[1]?.lines.bottom == ["", "2 / 2", ""])
    }

    @Test("論理ページと大きさの違う PDF のページには表示の紙に描かず、同じ大きさのページには描く")
    func pdfPagesOfOtherSizes() async throws {
        let themes = try PrintThemeLibrary.load()
        var settings = RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.options.furniture = .pageNumber
        let renderer = DocumentRenderer()
        let a4 = PrintLayout.a4Single.logicalPageSize(options: PrintOptions())
        for (size, expectsFurniture) in [(a4, true), (CGSize(width: 612, height: 792), false)] {
            let document = try RenderingFixtures.pdf(count: 1, size: size)
            let data = try #require(document.dataRepresentation())
            let prepared = try await renderer.prepare(DocumentSource(data: data, format: .pdf), settings: settings)
            #expect((prepared.viewFurniture[0] != nil) == expectsFurniture)
        }
    }

    @Test("刷るページの範囲で位置が番号と違うときは、左右を位置で決め、番号はページ自身のものを出す")
    func positionDiffersFromIndex() {
        var options = PrintOptions()
        options.furniture = sides()
        options.furniture.bottomCenter = "{ページ}"
        // The fifth page printed second sits on the left of a spread.
        let placement = PDFComposer.furniture(
            onPage: 4, at: 1, pageCount: 9, layout: .a4Duplex, options: options, context: .init())
        #expect(placement?.lines.top == ["右", "", "左"])
        #expect(placement?.lines.bottom == ["", "5", ""])
    }

    @Test("目次と右ページ始まりの白紙のある文書では、総ページは全部を数え、白紙には何も置かない", .timeLimit(.minutes(1)))
    func totalCountsContentsAndBlanks() async throws {
        let themes = try PrintThemeLibrary.load()
        var settings = RenderSettings(
            layout: .a4Duplex, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.finish.breaks.h1 = .rightPage
        settings.finish.legacyPresetContents.mode = .front
        settings.options.furniture = .name
        let source = DocumentSource(
            data: Data("# 第一章\n\n本文一\n\n# 第二章\n\n本文二\n\n# 第三章\n\n本文三\n".utf8), format: .markdown)
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let count = prepared.logicalDocument.pageCount
        #expect(prepared.addedContentsPages > 0)
        #expect(!prepared.blankPages.isEmpty)
        for index in 0..<count {
            if prepared.blankPages.contains(index) {
                #expect(prepared.viewFurniture[index] == nil)
            } else {
                #expect(prepared.viewFurniture[index]?.lines.bottom == ["", "\(index + 1) / \(count)", ""])
            }
        }
    }

    @Test("回した PDF のページと原点のずれた切り抜きでも、見える向きのページの上の余白に描く")
    func rotatedPDFWithOffsetCropBox() async throws {
        let a4 = PrintLayout.a4Single.logicalPageSize(options: PrintOptions())
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let original = try #require(PDFDocument(data: data as Data))
        let page = try #require(original.page(at: 0))
        // A landscape A4 crop turned a quarter: it reads as portrait A4.
        page.setBounds(CGRect(x: 20, y: 30, width: a4.height, height: a4.width), for: .cropBox)
        page.rotation = 90
        let bytes = try #require(original.dataRepresentation())
        var settings = RenderSettings(
            layout: .a4Single, theme: try #require(try PrintThemeLibrary.load().first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.documentName = "HEADERNAME.pdf"
        settings.options.furniture = .name
        let prepared = try await DocumentRenderer().prepare(
            DocumentSource(data: bytes, format: .pdf), settings: settings)
        let placement = try #require(prepared.viewFurniture[0])
        let plan = ViewPageLayout(
            pageCount: 1,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false)
        let bare = try #require(ViewPageDocument.make(prepared.viewDocument, plan: plan, margin: 0))
        let decorated = try #require(
            ViewPageDocument.make(prepared.viewDocument, plan: plan, margin: 0, furniture: [0: placement]))
        #expect(try !displayedInkInTopMargin(try #require(bare.page(at: 0))))
        #expect(try displayedInkInTopMargin(try #require(decorated.page(at: 0))))
    }

    /// Whether anything darker than the paper is drawn in the top margin of a page as it is displayed.
    private func displayedInkInTopMargin(_ page: PDFPage) throws -> Bool {
        let size = PageSizes.displayed(page.bounds(for: .cropBox).size, rotation: page.rotation)
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let margin = Int(points(15))
        return (0..<margin).contains { y in (0..<width).contains { x in bytes[(y * width + x) * 4] < 160 } }
    }

    @Test("絵文字は字形の輪郭がなくても表示の紙に絵として描き、ページの文字にはしない")
    func emojiIsDrawnAsPicture() throws {
        let source = try bodyPage()
        let placement = try headerPlacement(top: ["進捗 😀", "", ""])
        let plan = ViewPageLayout(
            pageCount: 1,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: true, showsNumbers: false)
        let decorated = try #require(
            ViewPageDocument.make(source, plan: plan, margin: points(15), furniture: [0: placement]))
        let page = try #require(decorated.page(at: 0))
        #expect(try colorfulInkInTopMargin(page))
        #expect(page.string?.contains("進捗") == false)
        #expect(page.string?.contains("😀") == false)
    }

    /// A header of the given texts on a portrait A4 page with 15 mm margins.
    private func headerPlacement(top: [String]) throws -> FurniturePlacement {
        var options = PrintOptions()
        options.furniture.topLeft = top[0]
        options.furniture.topCenter = top[1]
        options.furniture.topRight = top[2]
        return try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 1, layout: .a4Single, options: options, context: .init()))
    }

    /// Whether a colored, not gray, pixel is drawn in the top margin of a page.
    private func colorfulInkInTopMargin(_ page: PDFPage) throws -> Bool {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width)) * 2
        let height = Int(ceil(size.height)) * 2
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let margin = Int(points(15)) * 2
        return (0..<margin).contains { y in
            (0..<width).contains { x in
                let red = Int(bytes[(y * width + x) * 4])
                let green = Int(bytes[(y * width + x) * 4 + 1])
                let blue = Int(bytes[(y * width + x) * 4 + 2])
                return max(abs(red - green), abs(green - blue), abs(red - blue)) > 60
            }
        }
    }

    @Test("日をまたぐと、同じ設定のまま組版し直さずに用紙と表示の紙の日付が今日になる")
    func dateFollowsTheDay() async throws {
        final class Counter { var calls = 0 }
        final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
        let counter = Counter()
        let clock = Clock()
        let renderer = DocumentRenderer(paginate: { request in
            counter.calls += 1
            return try RenderingFixtures.pdf(count: 1, size: request.pageSize)
        })
        renderer.now = { clock.date }
        let themes = try PrintThemeLibrary.load()
        var settings = RenderSettings(
            layout: .a4Single, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.options.furniture = .nameAndDate
        // Digits and hyphens read back from the sheet's text as they were written.
        settings.options.furniture.dateFormat = "YYYY-MM-DD"
        let source = DocumentSource(data: Data("本文\n".utf8), format: .markdown)
        let yesterday = try await renderer.prepare(source, settings: settings)
        _ = try await renderer.composeSheet(for: yesterday)
        let before = settings.options.furniture.dateText(clock.date, language: settings.pageLanguage)
        #expect(renderer.furnitureDate(for: settings) == yesterday.furnitureDate)

        clock.date += 24 * 60 * 60
        let today = settings.options.furniture.dateText(clock.date, language: settings.pageLanguage)
        #expect(today != before)
        #expect(renderer.furnitureDate(for: settings) != yesterday.furnitureDate)
        let prepared = try await renderer.prepare(source, settings: settings)
        let sheet = try await renderer.composeSheet(for: prepared)
        #expect(counter.calls == 1)
        #expect(prepared.furnitureDate == today)
        #expect(prepared.viewFurniture[0]?.lines.top[2] == today)
        #expect(renderer.sheetCompositionCount == 2)
        #expect(sheet.sheetDocument.page(at: 0)?.string?.contains(today) == true)
    }

    @Test("飾ったページを一つの PDF に描いても、ページごとの PDF と同じ数・枠・文字・リンクの位置になる")
    func sharedResourcesMatchPagePerPDF() throws {
        let size = PrintLayout.a4Single.logicalPageSize(options: PrintOptions())
        let source = try RenderingFixtures.pdf(count: 4, size: size)
        let link = PDFAnnotation(
            bounds: CGRect(x: 40, y: 300, width: 120, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        source.page(at: 1)?.addAnnotation(link)
        var options = PrintOptions()
        options.furniture = .name
        var furniture: [Int: FurniturePlacement] = [:]
        for index in [0, 1, 2] {
            furniture[index] = PDFComposer.furniture(
                onPage: index, at: index, pageCount: 4, layout: .a4Single, options: options,
                context: PageFurniture.Context(fileName: "memo.md"))
        }
        let plan = ViewPageLayout(
            pageCount: 4,
            options: ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .instant, showsCoverAlone: true),
            hasLogicalMargins: true, showsNumbers: false)
        let marks = [ChangeMark(pageIndex: 2, rect: CGRect(x: 30, y: 100, width: 100, height: 40))]
        // Page 4 has nothing to draw and passes through; the spread adds blank pages.
        let shared = try #require(
            ViewPageDocument.make(source, plan: plan, margin: points(15), changeMarks: marks, furniture: furniture))
        let separate = try #require(
            ViewPageDocument.make(
                source, plan: plan, margin: points(15), changeMarks: marks, furniture: furniture,
                sharesResources: false))
        #expect(shared.pageCount == separate.pageCount)
        for index in 0..<shared.pageCount {
            let left = try #require(shared.page(at: index))
            let right = try #require(separate.page(at: index))
            #expect(left.bounds(for: .mediaBox) == right.bounds(for: .mediaBox))
            #expect(left.bounds(for: .cropBox) == right.bounds(for: .cropBox))
            #expect(left.rotation == right.rotation)
            #expect(left.string == right.string)
            #expect(left.annotations.map(\.bounds) == right.annotations.map(\.bounds))
            #expect(left.annotations.map(\.url) == right.annotations.map(\.url))
        }
        #expect(shared.findString("PAGE-2", withOptions: []).count == 1)
        #expect(shared.findString("memo", withOptions: []).isEmpty)
    }
}
