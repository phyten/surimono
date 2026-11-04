import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// Note pages among real pages: the order of the logical pages and what the sheets make of them.
@MainActor
struct NotePagesRenderingTests {
    private func settings(_ layout: PrintLayout = .a4BookletA5) throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: layout, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func notes(
        _ placement: NotePagePlan.Placement, presetID: String = "gingham"
    ) throws -> NotePages {
        let preset = try #require(NotePaperPreset.preset(id: presetID))
        return NotePages(isEnabled: true, placement: placement, presetID: preset.id, style: preset.style)
    }

    private func pdf(_ count: Int) throws -> DocumentSource {
        let data = try #require(try RenderingFixtures.pdf(count: count).dataRepresentation())
        return DocumentSource(data: data, format: .pdf)
    }

    private func texts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test("ノートが既定のオフなら PDF のページは増えない")
    func offByDefault() async throws {
        let prepared = try await DocumentRenderer().prepare(try pdf(3), settings: try settings())
        #expect(prepared.logicalDocument.pageCount == 3)
        #expect(prepared.notePages.isEmpty)
    }

    @Test("左がノートの 4 ページの PDF は 8 ページになり、冊子の用紙 2 枚に刷る")
    func spreadLeftOnPDF() async throws {
        var settings = try settings()
        settings.notes = try notes(.spreadLeft)
        let renderer = DocumentRenderer()
        let result = try await renderer.render(try pdf(4), settings: settings)
        #expect(texts(result.logicalDocument) == ["PAGE-1", "", "PAGE-2", "", "PAGE-3", "", "PAGE-4", ""])
        #expect(result.addedNotePages == 4)
        #expect(result.plan.sheetCount == 2)
        #expect(result.sheetDocument.pageCount == 4)
    }

    @Test("右がノートなら本文はいつも見開きの左に来る")
    func spreadRightOnPDF() async throws {
        var settings = try settings()
        settings.notes = try notes(.spreadRight)
        let prepared = try await DocumentRenderer().prepare(try pdf(2), settings: settings)
        #expect(texts(prepared.logicalDocument) == ["", "PAGE-1", "", "PAGE-2", ""])
    }

    @Test("両面の裏は本文の裏にノートを置く")
    func duplexBack() async throws {
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.duplexBack)
        let result = try await DocumentRenderer().render(try pdf(2), settings: settings)
        #expect(texts(result.logicalDocument) == ["PAGE-1", "", "PAGE-2", ""])
        #expect(result.sheetDocument.pageCount == 4)
    }

    @Test("章の終わりは PDF のしおりで章を見分ける")
    func chapterEndOnPDF() async throws {
        let document = try RenderingFixtures.pdf(count: 4)
        let root = PDFOutline()
        for (position, page) in [0, 2].enumerated() {
            let item = PDFOutline()
            item.label = "章 \(position + 1)"
            item.destination = PDFDestination(page: try #require(document.page(at: page)), at: .zero)
            root.insertChild(item, at: position)
        }
        document.outlineRoot = root
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.chapterEnd)
        let source = DocumentSource(data: try #require(document.dataRepresentation()), format: .pdf)
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        #expect(texts(prepared.logicalDocument) == ["PAGE-1", "PAGE-2", "", "PAGE-3", "PAGE-4", ""])
    }

    @Test("章の終わりは、章のない文書では最後に 1 ページだけ足す")
    func chapterEndWithoutChapters() async throws {
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.chapterEnd)
        let prepared = try await DocumentRenderer().prepare(try pdf(3), settings: settings)
        #expect(texts(prepared.logicalDocument) == ["PAGE-1", "PAGE-2", "PAGE-3", ""])
    }

    @Test("線を変えても文書を組み直さず、入れ方を変えると列だけ作り直す")
    func styleKeepsLayout() async throws {
        var settings = try settings()
        settings.notes = try notes(.spreadLeft)
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf(count: 2) })
        let source = DocumentSource(data: Data("本文".utf8), format: .html)
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        settings.notes.style.spacingInMillimeters = 9
        let changed = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        #expect(changed.logicalDocument.pageCount == 4)
        settings.notes.placement = .spreadRight
        let moved = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        #expect(moved.logicalDocument.pageCount == 5)
    }

    @Test("同じノートでは同じ用紙を使い回す")
    func sheetsAreReused() async throws {
        var settings = try settings()
        settings.notes = try notes(.spreadLeft)
        let renderer = DocumentRenderer()
        let source = try pdf(2)
        _ = try await renderer.render(source, settings: settings)
        _ = try await renderer.render(source, settings: settings)
        #expect(renderer.sheetCompositionCount == 1)
    }

    @Test("ノートを切ると文書のページへ戻り、キャッシュのページは増えていない")
    func cacheStaysClean() async throws {
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.duplexBack)
        let renderer = DocumentRenderer()
        let source = try pdf(2)
        #expect(try await renderer.prepare(source, settings: settings).logicalDocument.pageCount == 4)
        settings.notes.isEnabled = false
        #expect(try await renderer.prepare(source, settings: settings).logicalDocument.pageCount == 2)
    }

    @Test("ヘッダーと番号はノートに入らず、ノート側の番号の設定に従う")
    func furnitureStaysOffNotes() async throws {
        var settings = try settings(.a4Single)
        settings.notes = try notes(.duplexBack)
        settings.options.furniture.bottomCenter = "第{ページ}面"
        let result = try await DocumentRenderer().render(try pdf(2), settings: settings)
        let sheets = texts(result.sheetDocument)
        #expect(sheets[0].contains("面"))
        #expect(sheets[1].isEmpty)
        #expect(sheets[2].contains("面") && sheets[2].contains("3"))
        #expect(sheets[3].isEmpty)

        settings.notes = try notes(.duplexBack, presetID: "hougan")
        let numbered = try await DocumentRenderer().render(try pdf(1), settings: settings)
        #expect(texts(numbered.sheetDocument)[1] == "2")
    }

    @Test("目次の番号はノートの入ったあとのページを指す", .timeLimit(.minutes(1)))
    func contentsCountNotes() async throws {
        var settings = try settings(.a4Duplex)
        settings.finish.breaks.h1 = .page
        settings.finish.toc.mode = .front
        settings.notes = try notes(.duplexBack)
        let source = DocumentSource(data: Data("# 第一章\n\n一\n\n# 第二章\n\n二\n".utf8), format: .markdown)
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let pages = texts(prepared.logicalDocument)
        // 目次・ノート・第一章・ノート・第二章・ノート
        #expect(pages.count == 6)
        #expect(pages[0].contains("第一章") && pages[0].contains("3"))
        #expect(pages[0].contains("第二章") && pages[0].contains("5"))
        #expect(pages[1].isEmpty)
        #expect(pages[2].contains("一"))
        #expect(pages[4].contains("二"))
        #expect(prepared.addedContentsPages == 1)
        #expect(prepared.notePages.count == 3)
    }

    @Test("章の終わりのノートは見出しのページで決まり、右ページ始まりは数え直す", .timeLimit(.minutes(1)))
    func chapterEndOnText() async throws {
        var settings = try settings(.a4Duplex)
        settings.finish.breaks.h1 = .rightPage
        settings.notes = try notes(.chapterEnd)
        let source = DocumentSource(data: Data("# 第一章\n\n一\n\n# 第二章\n\n二\n".utf8), format: .markdown)
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let pages = texts(prepared.logicalDocument)
        #expect(pages.count == 4)
        #expect(pages[0].contains("第一章"))
        #expect(pages[1].isEmpty)
        #expect(pages[2].contains("第二章"))
        #expect(pages[3].isEmpty)
        #expect(prepared.blankPages.isEmpty)
    }

    @Test("内側と外側の余白はノートのあとの左右で決まり、ノートは動かさない", .timeLimit(.minutes(1)))
    func mirroredMargins() async throws {
        var settings = try settings(.a4Duplex)
        settings.options.margins = PageMargins(top: 15, left: 30, bottom: 15, right: 10)
        settings.options.mirrorsMargins = true
        settings.notes = try notes(.spreadRight, presetID: "hougan")
        let source = DocumentSource(data: Data("本文の見本".utf8), format: .markdown)
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        // 右がノートなら本文は 2 ページ目（左）に来るので、内側の余白は右へ移る
        let body = try #require(prepared.logicalDocument.page(at: 1))
        let ink = try RenderingFixtures.inkColumns(body)
        let width = body.bounds(for: .mediaBox).width
        #expect(ink.lowerBound < Int(width * 0.2))

        let notePage = try #require(prepared.logicalDocument.page(at: 0))
        settings.options.mirrorsMargins = false
        let plain = try await DocumentRenderer().prepare(source, settings: settings)
        #expect(
            try RenderingFixtures.inkColumns(notePage)
                == RenderingFixtures.inkColumns(try #require(plain.logicalDocument.page(at: 0))))
    }

    @Test("画像の束にもノートが入る")
    func imageBundle() async throws {
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.duplexBack)
        let image = try RenderingFixtures.image()
        let first = DocumentSource.Image(data: image, fileURL: URL(fileURLWithPath: "/tmp/a.tiff"))
        let second = DocumentSource.Image(data: image, fileURL: URL(fileURLWithPath: "/tmp/b.tiff"))
        let prepared = try await DocumentRenderer().prepare(.images([first, second]), settings: settings)
        #expect(prepared.logicalDocument.pageCount == 4)
    }

    @Test("合本と 3枚＋メモにはノートを入れない")
    func notForBindersAndHandouts() async throws {
        var settings = try settings(.a4Duplex)
        settings.notes = try notes(.duplexBack)
        let binder = try await DocumentRenderer().prepare(.binder([try pdf(2)]), settings: settings)
        #expect(binder.logicalDocument.pageCount == 2)
        settings.layout = .a4Handout3
        let handout = try await DocumentRenderer().prepare(try pdf(2), settings: settings)
        #expect(handout.logicalDocument.pageCount == 2)
    }

    @Test("紙に収まらない線はノートのエラーになる")
    func invalidStyle() async throws {
        var settings = try settings()
        settings.notes = try notes(.spreadLeft, presetID: "hougan")
        settings.notes.style.marginInMillimeters = 90
        await #expect(throws: DocumentRenderer.RenderingError.invalidNotePage) {
            try await DocumentRenderer().prepare(try pdf(1), settings: settings)
        }
    }

    @Test("棚の見本は紙の白地に線が描かれた小さな画になる")
    func swatch() throws {
        for preset in NotePaperPreset.all {
            let image = try #require(
                NotePageDrawing.swatch(
                    style: preset.style, pageSize: PaperSize.a4.size, size: CGSize(width: 60, height: 60),
                    lineScale: 3.6))
            #expect(image.width == 120)
        }
    }

    @Test("線の種類の見本はどれも線が見える", arguments: NotePaperStyle.Kind.allCases.filter { $0 != .plain })
    func kindSwatches(kind: NotePaperStyle.Kind) throws {
        let style = NotePaperStyle(
            kind: kind, weightInMillimeters: 0.5, spacingInMillimeters: 5, marginInMillimeters: 3,
            colorHex: "#57585D", header: .init(date: false, title: false, pageNumber: false))
        let image = try #require(
            NotePageDrawing.swatch(
                style: style, pageSize: CGSize(width: 96.4, height: 68), size: CGSize(width: 34, height: 24)))
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data.contains { $0 < 200 })
    }
}
