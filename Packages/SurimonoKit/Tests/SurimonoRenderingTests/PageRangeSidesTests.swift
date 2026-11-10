import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// A range can put a page on the other side of a spread than the one it was laid out for. Its inside margin and the
/// swapped header then follow its place among the printed pages, while its number stays the document's.
@MainActor
struct PageRangeSidesTests {
    /// Inside 10 mm, outside 20 mm: a page on the swapped side is laid out 10 mm (28.35 pt) to the right.
    private func settings(_ layout: PrintLayout, range: PageRange = .all) -> RenderSettings {
        var settings = RenderSettings(
            layout: layout, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.options.margins = PageMargins(top: 15, left: 10, bottom: 15, right: 20)
        settings.options.mirrorsMargins = true
        settings.pageRange = range
        return settings
    }

    private var options: PrintOptions { settings(.a4Duplex).options }

    private let text = DocumentSource(data: Data("# Sides".utf8), format: .markdown)

    /// Every page has a black square in its bottom left corner, 12 pt wide.
    private func renderer(pages: Int) -> DocumentRenderer {
        DocumentRenderer(paginate: { request in try RenderingFixtures.pdf(count: pages, size: request.pageSize) })
    }

    /// Where the square of the logical page `index` is on its sheet: at the page's edge, or moved toward the outside.
    private func square(of index: Int, in result: RenderResult) throws -> (atEdge: Bool, moved: Bool) {
        let side = try #require(result.plan.sides.firstIndex { $0.slots.contains(index) })
        let slot = try #require(result.plan.sides[side].slots.firstIndex(of: index))
        let page = try #require(result.sheetDocument.page(at: side))
        let left = Int((result.layout.slotRect(at: slot).minX * result.layout.sheetSize.width).rounded())
        return (
            try RenderingFixtures.pixel(page, x: left + 5, y: 5)[0] < 60,
            try RenderingFixtures.pixel(page, x: left + 34, y: 5)[0] < 60
        )
    }

    @Test("両面の 2-5 は、先頭になった 2 ページ目を表の位置へ戻し、3 ページ目を裏の位置へ動かす")
    func duplexRange() async throws {
        let result = try await renderer(pages: 6).render(
            text, settings: settings(.a4Duplex, range: PageRange([2...5])))
        #expect(result.plan.sides.map(\.slots) == [[1], [2], [3], [4]])
        #expect(try square(of: 1, in: result) == (true, false))
        #expect(try square(of: 2, in: result) == (false, true))
        #expect(try square(of: 3, in: result) == (true, false))
        #expect(try square(of: 4, in: result) == (false, true))
    }

    @Test("全ページの両面は、今までどおり偶数ページだけが動いている")
    func duplexWhole() async throws {
        let result = try await renderer(pages: 4).render(text, settings: settings(.a4Duplex))
        #expect(try square(of: 0, in: result) == (true, false))
        #expect(try square(of: 1, in: result) == (false, true))
        #expect(try square(of: 2, in: result) == (true, false))
        #expect(try square(of: 3, in: result) == (false, true))
    }

    @Test("とびとびの 1,3,4 は、表裏の変わる 3 ページ目と 4 ページ目だけを直す")
    func scatteredRange() async throws {
        let result = try await renderer(pages: 6).render(
            text, settings: settings(.a4Duplex, range: PageRange([1...1, 3...4])))
        #expect(try square(of: 0, in: result) == (true, false))
        #expect(try square(of: 2, in: result) == (false, true))
        #expect(try square(of: 3, in: result) == (true, false))
    }

    @Test("左とじの冊子の 2-5 は、冊子の中の位置で内側の余白を決める")
    func leftBoundBooklet() async throws {
        let result = try await renderer(pages: 6).render(
            text, settings: settings(.a3BookletA4, range: PageRange([2...5])))
        #expect(result.plan.sides.map(\.slots) == [[4, 1], [2, 3]])
        #expect(try square(of: 1, in: result) == (true, false))
        #expect(try square(of: 2, in: result) == (false, true))
        #expect(try square(of: 3, in: result) == (true, false))
        #expect(try square(of: 4, in: result) == (false, true))
    }

    @Test("右とじの冊子の 2-5 は、先頭になった 2 ページ目から左右を入れ替える")
    func rightBoundBooklet() async throws {
        let result = try await renderer(pages: 6).render(
            text, settings: settings(.a3BookletA4.bound(.right), range: PageRange([2...5])))
        #expect(try square(of: 1, in: result) == (false, true))
        #expect(try square(of: 2, in: result) == (true, false))
        #expect(try square(of: 3, in: result) == (false, true))
        #expect(try square(of: 4, in: result) == (true, false))
    }

    @Test("全ページを覆う範囲は範囲なしと同じ用紙のキーになり、同じ用紙をそのまま使う")
    func coveringRangeKeepsSheets() async throws {
        let renderer = renderer(pages: 4)
        let whole = try await renderer.render(text, settings: settings(.a3BookletA4))
        let covering = try await renderer.render(text, settings: settings(.a3BookletA4, range: PageRange([1...4])))
        #expect(covering.sheetDocument === whole.sheetDocument)
        #expect(renderer.sheetCompositionCount == 1)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("直す量は内側と外側の余白の差で、表裏の変わるページだけに付く")
    func corrections() {
        let sides = PDFComposer.LaidOutSides(movesContent: true)
        let shift = 10 * 72 / 25.4
        let duplex = PDFComposer.sideCorrections(
            pages: [1, 2, 3, 4], layout: .a4Duplex, options: options, sides: sides)
        #expect(duplex.keys.sorted() == [1, 2, 3, 4])
        #expect(abs((duplex[1] ?? 0) + shift) < 0.001)
        #expect(abs((duplex[2] ?? 0) - shift) < 0.001)
        let right = PDFComposer.sideCorrections(
            pages: [1, 2, 3, 4], layout: .a3BookletA4.bound(.right), options: options, sides: sides)
        #expect(abs((right[1] ?? 0) - shift) < 0.001)
        #expect(abs((right[2] ?? 0) + shift) < 0.001)
        let scattered = PDFComposer.sideCorrections(
            pages: [0, 2, 3], layout: .a3BookletA4, options: options, sides: sides)
        #expect(scattered.keys.sorted() == [2, 3])
    }

    @Test("表裏の変わらない 1,4,5 と、範囲なしと、片面には直す所がない")
    func nothingToCorrect() {
        let sides = PDFComposer.LaidOutSides(movesContent: true)
        #expect(
            PDFComposer.sideCorrections(pages: [0, 3, 4], layout: .a4Duplex, options: options, sides: sides) == [:])
        #expect(PDFComposer.sideCorrections(pages: nil, layout: .a4Duplex, options: options, sides: sides) == [:])
        #expect(PDFComposer.sideCorrections(pages: [1, 2], layout: .a4Single, options: options, sides: sides) == [:])
    }

    @Test("PDF のページとノートのページは組むときに動かしていないので、範囲でも動かさない")
    func pagesThatNeverMoved() {
        #expect(
            PDFComposer.sideCorrections(
                pages: [1, 2], layout: .a4Duplex, options: options, sides: PDFComposer.LaidOutSides()) == [:])
        let noted = PDFComposer.sideCorrections(
            pages: [1, 2], layout: .a4Duplex, options: options,
            sides: PDFComposer.LaidOutSides(movesContent: true, fixedPages: [1]))
        #expect(noted.keys.sorted() == [2])
    }

    @Test("PDF の範囲はページを動かさず、そのまま用紙に載せる")
    func pdfStaysWhole() async throws {
        let source = DocumentSource(
            data: try #require(RenderingFixtures.pdf(count: 6, size: PaperSize.a4.size).dataRepresentation()),
            format: .pdf)
        let result = try await DocumentRenderer().render(
            source, settings: settings(.a4Duplex, range: PageRange([2...5])))
        #expect(try square(of: 1, in: result) == (true, false))
        #expect(try square(of: 2, in: result) == (true, false))
    }

    @Test("範囲のヘッダーは刷る位置で左右を入れ替え、番号と総数は文書のままにする")
    func furnitureFollowsPosition() async throws {
        var options = options
        options.furniture = .name
        options.furniture.swapsOnSpreads = true
        let source = try RenderingFixtures.pdf(count: 12, size: PaperSize.a4.size)
        let output = try await PDFComposer().compose(
            source, layout: .a4Duplex, options: options, furniture: PageFurniture.Context(fileName: "NAME"),
            pages: [1, 2])
        func header(_ index: Int, left: Bool) throws -> String {
            let page = try #require(output.page(at: index))
            let rect = CGRect(x: left ? 0 : 298, y: 800, width: 297, height: 42)
            return (page.selection(for: rect)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func footer(_ index: Int) throws -> String {
            let page = try #require(output.page(at: index))
            return (page.selection(for: CGRect(x: 0, y: 0, width: 595, height: 42))?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Page 2 is the first page printed, so it is a front; page 3 is its back.
        #expect(try header(0, left: true) == "NAME")
        #expect(try header(0, left: false) == "")
        #expect(try header(1, left: true) == "")
        #expect(try header(1, left: false) == "NAME")
        #expect(try footer(0) == "2 / 12")
        #expect(try footer(1) == "3 / 12")
    }

    @Test("折ってみるの冊子も、同じ量だけページの中身を動かす")
    func fittedMovesContent() async throws {
        let source = try RenderingFixtures.pdf(count: 2, size: PaperSize.a4.size)
        let book = try await PDFComposer().fitted(source, pageSize: PaperSize.a4.size, corrections: [1: 28.35])
        #expect(try RenderingFixtures.pixel(#require(book.page(at: 0)), x: 5, y: 5)[0] < 60)
        #expect(try RenderingFixtures.pixel(#require(book.page(at: 1)), x: 5, y: 5)[0] > 240)
        #expect(try RenderingFixtures.pixel(#require(book.page(at: 1)), x: 34, y: 5)[0] < 60)
    }
}
