import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// The finish on real pages: WebKit's page breaks and the text it leaves in the PDF.
@MainActor
struct PrintFinishRenderingTests {
    private func settings(_ layout: PrintLayout = .a4Single) throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: layout, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func markdown(_ text: String) -> DocumentSource {
        DocumentSource(data: Data(text.utf8), format: .markdown)
    }

    private func logicalPages(_ source: DocumentSource, _ settings: RenderSettings) async throws -> PDFDocument {
        try await DocumentRenderer().prepare(source, settings: settings).logicalDocument
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    private let chapters = "# 第一章\n\n本文一\n\n# 第二章\n\n本文二\n\n# 第三章\n\n本文三\n"

    @Test("既定では見出しで改ページしない", .timeLimit(.minutes(1)))
    func noBreakByDefault() async throws {
        #expect(try await logicalPages(markdown(chapters), try settings()).pageCount == 1)
    }

    @Test("章の前の改ページは最初の見出しの前を除いて章ごとにページを分ける", .timeLimit(.minutes(1)))
    func breaksBeforeChapters() async throws {
        var settings = try settings()
        settings.finish.breaks.h1 = .page
        let pages = texts(try await logicalPages(markdown("前書き\n\n" + chapters), settings))
        #expect(pages.count == 3)
        #expect(pages[0].contains("前書き") && pages[0].contains("第一章"))
        #expect(pages[2].contains("第三章"))
    }

    @Test("右ページからは片面では白紙を足さず、両面では章を奇数ページに置く", .timeLimit(.minutes(1)))
    func rightPages() async throws {
        var settings = try settings()
        settings.finish.breaks.h1 = .rightPage
        #expect(try await logicalPages(markdown(chapters), settings).pageCount == 3)
        settings.layout = .a4Duplex
        let prepared = try await DocumentRenderer().prepare(markdown(chapters), settings: settings)
        let pages = texts(prepared.logicalDocument)
        #expect(pages.count == 5)
        #expect(pages[0].contains("第一章"))
        #expect(pages[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(pages[2].contains("第二章"))
        #expect(pages[4].contains("第三章"))
        #expect(prepared.blankPages == [1, 3])
    }

    @Test("原文の記法の改ページは既定で効き、切ると何も出さない", .timeLimit(.minutes(1)))
    func sourceBreaks() async throws {
        let source = markdown("前\n\n<!--BREAK-->\n\n中\n\n\\newpage\n\n後\n")
        var settings = try settings()
        #expect(try await logicalPages(source, settings).pageCount == 3)
        settings.finish.breaks.ignoredSyntaxes = [.comment, .newpage]
        let pages = texts(try await logicalPages(source, settings))
        #expect(pages.count == 1)
        #expect(!pages[0].contains("newpage"))
    }

    @Test("--- は頼んだときだけ改ページにする", .timeLimit(.minutes(1)))
    func thematicBreak() async throws {
        let source = markdown("前\n\n---\n\n後\n")
        var settings = try settings()
        #expect(try await logicalPages(source, settings).pageCount == 1)
        settings.finish.breaks.breaksAtThematicBreaks = true
        #expect(try await logicalPages(source, settings).pageCount == 2)
    }

    @Test("見出しの規則と原文の改ページが同じ場所に重なっても白紙にしない", .timeLimit(.minutes(1)))
    func overlappingBreaks() async throws {
        var settings = try settings()
        settings.finish.breaks.h1 = .page
        let source = markdown("# 一\n\n本文\n\n<!--BREAK-->\n\n# 二\n\n本文\n")
        #expect(try await logicalPages(source, settings).pageCount == 2)
    }

    @Test("先頭に足す目次は同じ組版で見出しの番号を載せ、本文の番号と合う", .timeLimit(.minutes(1)))
    func frontContents() async throws {
        var settings = try settings()
        settings.finish.breaks.h1 = .page
        settings.finish.toc.mode = .front
        let prepared = try await DocumentRenderer().prepare(markdown(chapters), settings: settings)
        let pages = texts(prepared.logicalDocument)
        #expect(pages.count == 4)
        #expect(pages[0].contains("目次"))
        let lines = pages[0].components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains { $0.contains("第一章") })
        // The contents take page 1, so the three chapters stand on pages 2, 3 and 4.
        #expect(pages[0].contains("2") && pages[0].contains("3") && pages[0].contains("4"))
        #expect(pages[1].contains("第一章"))
        #expect(prepared.addedContentsPages == 1)
    }

    @Test("目次が 2 ページになっても本文の番号と合う", .timeLimit(.minutes(1)))
    func longContents() async throws {
        let titles = (1...40).map { "章\($0)番" }
        let text = titles.map { "# \($0)\n\n本文\n" }.joined(separator: "\n")
        var settings = try settings()
        settings.finish.breaks.h1 = .page
        settings.finish.toc.mode = .front
        let prepared = try await DocumentRenderer().prepare(markdown(text), settings: settings)
        #expect(prepared.addedContentsPages == 2)
        let pages = texts(prepared.logicalDocument)
        #expect(pages.count == 42)
        #expect(pages[2].contains("章1番"))
        // The first chapter comes after two pages of contents.
        let row = pages[0].components(separatedBy: .newlines).first { $0.contains("章1番") }
        #expect(row?.contains("3") == true)
    }

    @Test("切った記法の直後の見出しは見出しの規則で改ページする", .timeLimit(.minutes(1)))
    func headingAfterIgnoredBreak() async throws {
        var settings = try settings()
        settings.finish.breaks.h1 = .page
        settings.finish.breaks.ignoredSyntaxes = [.comment]
        let source = markdown("# 一\n\n本文\n\n<!--BREAK-->\n\n# 二\n\n本文\n")
        #expect(try await logicalPages(source, settings).pageCount == 2)
    }

    @Test("先頭に足すと原文の目次は隠れ、残す設定なら両方出る", .timeLimit(.minutes(1)))
    func sourceContentsWithFront() async throws {
        let source = markdown("[TOC]\n\n# 第一章\n\n本文\n")
        var settings = try settings()
        settings.finish.toc.mode = .hidden
        #expect(
            texts(try await logicalPages(source, settings)).joined().components(separatedBy: "第一章").count - 1 == 1)
        settings.finish.toc.mode = .front
        let front = texts(try await logicalPages(source, settings))
        #expect(front.count == 2)
        #expect(front[1].components(separatedBy: "第一章").count - 1 == 1)
        settings.finish.toc.keepsSourceTOC = true
        let both = texts(try await logicalPages(source, settings))
        #expect(both[1].components(separatedBy: "第一章").count - 1 == 2)
    }

    @Test("原文の目次があっても右ページの章は見出しの本物の位置で判定する", .timeLimit(.minutes(1)))
    func rightPagesWithSourceContents() async throws {
        var settings = try settings(.a4Duplex)
        settings.finish.breaks.h1 = .rightPage
        let pages = texts(try await logicalPages(markdown("[TOC]\n\n" + chapters), settings))
        #expect(pages.count == 5)
        #expect(pages[2].contains("第二章"))
        #expect(pages[4].contains("第三章"))
    }

    @Test("ヘッダーの文字は PDF に入り、足した白紙には入らない", .timeLimit(.minutes(1)))
    func furnitureText() async throws {
        var settings = try settings(.a4Duplex)
        settings.finish.breaks.h1 = .rightPage
        settings.options.furniture = .name
        settings.documentName = "手引き.md"
        let result = try await DocumentRenderer().render(markdown(chapters), settings: settings)
        let sides = texts(result.sheetDocument)
        #expect(sides[0].contains("手引き.md"))
        #expect(sides[0].contains("1 / 5"))
        #expect(!sides[1].contains("手引き.md"))
        #expect(sides[2].contains("3 / 5"))
    }

    @Test("ヘッダーは PDF の文書にも画像の文書にも効く", .timeLimit(.minutes(1)))
    func furnitureOnEveryFormat() async throws {
        var settings = try settings()
        settings.options.furniture = .name
        settings.documentName = "資料"
        let pdf = DocumentSource(
            data: try #require(RenderingFixtures.pdf(count: 2).dataRepresentation()), format: .pdf)
        let sheets = try await DocumentRenderer().render(pdf, settings: settings).sheetDocument
        #expect(texts(sheets)[1].contains("2 / 2"))
        #expect(texts(sheets)[0].contains("資料"))
        let image = DocumentSource(data: try RenderingFixtures.image(), format: .image)
        #expect(texts(try await DocumentRenderer().render(image, settings: settings).sheetDocument)[0].contains("資料"))
        let html = DocumentSource(
            data: Data("<title>題</title><p>本文</p>".utf8), format: .html)
        settings.options.furniture.topLeft = "{題名}"
        #expect(texts(try await DocumentRenderer().render(html, settings: settings).sheetDocument)[0].contains("題"))
    }

    @Test("最初のページに入れない設定は 1 ページ目を飛ばす", .timeLimit(.minutes(1)))
    func skipsFirstPage() async throws {
        var settings = try settings()
        settings.options.furniture.bottomCenter = "第{ページ}面"
        settings.options.furniture.skipsFirstPage = true
        let pdf = DocumentSource(
            data: try #require(RenderingFixtures.pdf(count: 2).dataRepresentation()), format: .pdf)
        let sides = texts(try await DocumentRenderer().render(pdf, settings: settings).sheetDocument)
        #expect(!sides[0].contains("面"))
        #expect(sides[1].contains("面"))
    }

    @Test("日付は今日を書式で出す", .timeLimit(.minutes(1)))
    func date() async throws {
        var settings = try settings()
        settings.options.furniture.topRight = "{日付}"
        settings.options.furniture.dateFormat = "YYYY"
        let renderer = DocumentRenderer()
        renderer.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        let pdf = DocumentSource(data: try #require(RenderingFixtures.pdf().dataRepresentation()), format: .pdf)
        #expect(texts(try await renderer.render(pdf, settings: settings).sheetDocument)[0].contains("2027"))
    }

    @Test("余白は上下左右を別々に組版へ通す", .timeLimit(.minutes(1)))
    func sideMargins() async throws {
        var settings = try settings()
        settings.options.margins = PageMargins(top: 10, left: 30, bottom: 20, right: 5)
        var requests: [WebPaginator.Margins] = []
        let renderer = DocumentRenderer(paginate: { request in
            requests.append(request.margins)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        _ = try await renderer.prepare(markdown("本文"), settings: settings)
        #expect(requests.first == WebPaginator.Margins(settings.options.margins))
    }

    @Test("余白を内側・外側にすると偶数ページの本文だけが動く", .timeLimit(.minutes(1)))
    func mirroredMargins() async throws {
        var settings = try settings(.a4Duplex)
        settings.options.margins = PageMargins(top: 15, left: 30, bottom: 15, right: 10)
        let source = markdown("一\n\n<!--BREAK-->\n\n二\n")
        func textStart(_ page: PDFPage?) throws -> CGFloat {
            let page = try #require(page)
            let box = page.bounds(for: .cropBox)
            let bounds = try #require(page.selection(for: box)).bounds(for: page)
            return bounds.minX - box.minX
        }
        let plain = try await logicalPages(source, settings)
        settings.options.mirrorsMargins = true
        let mirrored = try await logicalPages(source, settings)
        #expect(mirrored.pageCount == 2)
        #expect(try abs(textStart(mirrored.page(at: 0)) - textStart(plain.page(at: 0))) < 0.5)
        // 20 mm between the two margins is 56.7 pt to the left.
        #expect(try abs(textStart(plain.page(at: 1)) - textStart(mirrored.page(at: 1)) - 56.7) < 1)
    }

    @Test("余白が奇数ページと偶数ページで入れ替わっても用紙の大きさは変わらない", .timeLimit(.minutes(1)))
    func mirroredSheets() async throws {
        var settings = try settings(.a4Duplex)
        settings.options.margins = PageMargins(top: 15, left: 30, bottom: 15, right: 10)
        settings.options.mirrorsMargins = true
        let result = try await DocumentRenderer().render(markdown("一\n\n<!--BREAK-->\n\n二\n"), settings: settings)
        let size = try #require(result.sheetDocument.page(at: 1)).bounds(for: .mediaBox).size
        #expect(abs(size.width - PaperSize.a4.size.width) < 0.5)
    }

    @Test("仕上げの変更はヘッダーだけなら組み直さず、改ページなら組み直す", .timeLimit(.minutes(1)))
    func caching() async throws {
        let renderer = DocumentRenderer(paginate: { request in try RenderingFixtures.pdf(size: request.pageSize) })
        var settings = try settings()
        let source = markdown("本文")
        _ = try await renderer.prepare(source, settings: settings)
        settings.options.furniture = .name
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        settings.finish.breaks.h1 = .page
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 2)
    }

    @Test("B4 中綴じは B5 の論理ページを面付けする", .timeLimit(.minutes(1)))
    func bSeriesBooklet() async throws {
        let pdf = DocumentSource(
            data: try #require(RenderingFixtures.pdf(count: 4, size: PaperSize.b5.size).dataRepresentation()),
            format: .pdf)
        let result = try await DocumentRenderer().render(pdf, settings: try settings(.b4BookletB5))
        let size = try #require(result.sheetDocument.page(at: 0)).bounds(for: .mediaBox).size
        #expect(abs(size.width - PaperSize.b4.size.height) < 0.5)
        #expect(result.plan.sheetCount == 1)
    }

    @Test("文書の数字を結果に載せる", .timeLimit(.minutes(1)))
    func facts() async throws {
        let prepared = try await DocumentRenderer().prepare(markdown("# 題\n\n本文\n"), settings: try settings())
        #expect(prepared.facts?.statistics.characters == 3)
        #expect(prepared.facts?.headings.map(\.text) == ["題"])
    }

    @Test("紙のあるテーマでは足した白紙と目次にも紙を敷き、動かした本文の下の紙は動かない", .timeLimit(.minutes(1)))
    func paperUnderFinishedPages() async throws {
        let previous = WebPaginator.clearBackground
        WebPaginator.clearBackground = { $0.setValue(false, forKey: "drawsBackground") }
        defer { WebPaginator.clearBackground = previous }
        _ = NSApplication.shared
        var settings = try settings(.a4Duplex)
        settings.theme = try #require(PrintThemeLibrary.load().first { $0.id == "washi" })
        settings.finish.breaks.h1 = .rightPage
        settings.finish.toc.mode = .front
        settings.options.margins = PageMargins(top: 15, left: 30, bottom: 15, right: 10)
        settings.options.mirrorsMargins = true
        let document = try await logicalPages(markdown(chapters), settings)
        // Contents, blank, then the three chapters on odd pages with a blank before each of the last two.
        #expect(document.pageCount == 7)
        for index in 0..<document.pageCount {
            let pixels = try PagePixels(try #require(document.page(at: index)))
            for point in [CGPoint(x: 6, y: 6), CGPoint(x: 590, y: 838)] {
                let color = pixels.color(atX: point.x, y: point.y)
                #expect(abs(color.red - 0xfc) <= 3 && abs(color.blue - 0xf5) <= 3, "page \(index + 1)")
            }
        }
    }
}
