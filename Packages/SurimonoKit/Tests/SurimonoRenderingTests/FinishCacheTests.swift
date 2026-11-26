import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// The tray's axes against the renderer's caches: what must lay the text out again, and what only composes the sheets.
@MainActor
struct FinishCacheTests {
    private let source = DocumentSource(data: Data("# 一\n\n本文\n\n# 二\n\n本文\n".utf8), format: .markdown)

    private func settings(_ layout: PrintLayout = .a4Duplex) throws -> RenderSettings {
        let themes = try PrintThemeLibrary.load()
        return RenderSettings(
            layout: layout, theme: try #require(themes.first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func renderer() -> DocumentRenderer {
        DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf(count: 2) })
    }

    private let orgSource = DocumentSource(data: Data("#+OPTIONS: toc:nil\n* A\nA_1".utf8), format: .org).named(
        "sample.org")

    @Test("六形式の先頭の目次は全体の既定を使い、保存済みの文書指定と原稿の指定を優先する")
    func formatDefaults() async throws {
        let markup = "# Chapter\n\n## First\n\n### Nested\n\n## Second"
        let manuscripts: [(DocumentFormat, String)] = [
            (.markdown, markup), (.quarto, markup), (.rMarkdown, markup),
            (.rst, "First\n=====\n\nBody.\n\nNested\n------\n\nBody.\n\nSecond\n======\n\nBody."),
            (.asciidoc, "= Title\n\n== First\n\n=== Nested\n\n== Second"),
            (.mediawiki, "== First ==\n\n=== Nested ===\n\n== Second =="),
        ]
        for (format, text) in manuscripts {
            var settings = try settings()
            var pages: [String] = []
            let renderer = DocumentRenderer(paginate: { request in
                if case .html(let html, _) = request.source { pages.append(html) }
                return try RenderingFixtures.pdf(count: 1)
            })
            func rendersContents(_ text: String) async throws -> Bool {
                pages.removeAll()
                _ = try await renderer.prepare(
                    DocumentSource(data: Data(text.utf8), format: format), settings: settings)
                return try #require(pages.first).contains("<nav class=\"toc\"")
            }
            settings.formatReadingDefaults.set(
                .outline(present: true, depth: .all), for: .tableOfContents, format: format)
            #expect(try await rendersContents(text), "\(format)")
            let full = try #require(pages.first)
            #expect(DocumentOutline.sourceContentsEntries(inHTML: full).contains("Nested"), "\(format)")
            settings.formatReadingDefaults.set(
                .outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format)
            _ = try await rendersContents(text)
            let shallow = try #require(pages.first)
            #expect(
                !DocumentOutline.sourceContentsEntries(inHTML: shallow).contains("Nested"), "\(format)")
            settings.formatReading.set(
                .outline(present: false, depth: .all), for: .tableOfContents, format: format,
                defaults: settings.formatReadingDefaults)
            #expect(try await !rendersContents(text), "\(format)")
            if format == .markdown {
                #expect(try await rendersContents("---\ntoc: true\n---\n" + text))
            }
        }
    }

    @Test("他形式の目次と使わない行番号の変更は組版を増やさず、継承する既定を変えたときだけ組む")
    func inheritedDefaultsCache() async throws {
        var settings = try settings()
        var calls = 0
        let renderer = DocumentRenderer(paginate: { _ in
            calls += 1
            return try RenderingFixtures.pdf(count: 1)
        })
        _ = try await renderer.prepare(source, settings: settings)
        settings.formatReadingDefaults.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .quarto)
        settings.code = CodeStyle(lineNumbers: .init(source: .none))
        _ = try await renderer.prepare(source, settings: settings)
        #expect(calls == 1)
        settings.formatReadingDefaults.set(
            .outline(present: true, depth: .all), for: .tableOfContents, format: .markdown)
        _ = try await renderer.prepare(source, settings: settings)
        #expect(calls == 2)
        settings.code = CodeStyle(lineNumbers: .init(source: .none, blocks: .all))
        _ = try await renderer.prepare(source, settings: settings)
        #expect(calls == 3)

        let chosen = CodeBlockOptions(frame: .rule)
        settings.code.block = chosen
        _ = try await renderer.prepare(source, settings: settings)
        #expect(calls == 4)
        settings.code = CodeStyle(block: chosen, lineNumbers: .init(source: .everyFive, blocks: .everyFive))
        _ = try await renderer.prepare(source, settings: settings)
        #expect(calls == 4)
    }

    @Test("Org の全体既定だけを変えると、再組版した本文に番号と下付きが反映される")
    func orgDefaultsInvalidateCache() async throws {
        var settings = try settings()
        var pages: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { pages.append(html) }
            return try RenderingFixtures.pdf(count: 2)
        })
        _ = try await renderer.prepare(orgSource, settings: settings)
        settings.orgReading.defaults.sectionNumbers = .all
        let numbered = try await renderer.prepare(orgSource, settings: settings)
        settings.orgReading.defaults.scripts = .all
        _ = try await renderer.prepare(orgSource, settings: settings)
        #expect(renderer.logicalRenderCount == 3)
        try #require(pages.count == 3)
        #expect(!pages[0].contains("<span class=\"section-number-") && pages[0].contains("A_1"))
        #expect(pages[1].contains("<span class=\"section-number-1\">1.</span> A") && pages[1].contains("A_1"))
        #expect(pages[2].contains("A<sub>1</sub>"))
        #expect(numbered.facts?.headings.map(\.text) == ["1. A"])
    }

    @Test("Org の文書設定の目次だけを変えると、再組版した本文と見出し情報が更新される")
    func orgDocumentValueInvalidatesCache() async throws {
        var settings = try settings()
        settings.orgReading.setAllowsFileChanges(true, file: .init())
        var pages: [String] = []
        let renderer = DocumentRenderer(paginate: { request in
            if case .html(let html, _) = request.source { pages.append(html) }
            return try RenderingFixtures.pdf(count: 2)
        })
        let first = try await renderer.prepare(orgSource, settings: settings)
        let file = try #require(first.facts?.orgInstructions)
        #expect(settings.orgReading.resolve(.tableOfContents, file: file).source?.fileName == "sample.org")
        settings.orgReading.set(.levels(1), for: .tableOfContents, file: file)
        let second = try await renderer.prepare(orgSource, settings: settings)
        #expect(renderer.logicalRenderCount == 2)
        try #require(pages.count == 2)
        #expect(!pages[0].contains("<nav class=\"toc\""))
        #expect(pages[1].contains("<nav class=\"toc\"") && pages[1].contains("<a href=\"#a\">A</a>"))
        #expect(first.facts?.hasSourceContents == false && second.facts?.hasSourceContents == true)
        #expect(second.facts?.headings.map(\.text) == ["A"])
    }

    @Test("冊子のとじ方だけなら本文を組み直さず面付けを変える")
    func bindingComposesOnly() async throws {
        var settings = try settings(.a4BookletA5)
        let renderer = renderer()
        let left = try await renderer.render(source, settings: settings)
        settings.layout = settings.layout.bound(.right)
        let right = try await renderer.render(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 2)
        #expect(left.logicalDocument === right.logicalDocument)
        #expect(right.plan.sides.map(\.slots) == [[0, nil], [nil, 1]])
    }

    @Test("内外余白のある冊子はとじ方を変えると本文の移動先も更新する")
    func bindingMirrorsContent() async throws {
        var settings = try settings(.a4BookletA5)
        settings.options.margins = PageMargins(top: 15, left: 15, bottom: 15, right: 10)
        settings.options.mirrorsMargins = true
        let renderer = DocumentRenderer(paginate: { request in
            try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let left = try await renderer.prepare(source, settings: settings)
        settings.layout = settings.layout.bound(.right)
        let right = try await renderer.prepare(source, settings: settings)
        func x(_ document: PDFDocument, index: Int) throws -> CGFloat {
            let page = try #require(document.page(at: index))
            let selection = try #require(document.findString("PAGE-\(index + 1)", withOptions: []).first)
            return selection.bounds(for: page).minX
        }
        #expect(renderer.logicalRenderCount == 2)
        let firstShift = try x(right.logicalDocument, index: 0) - x(left.logicalDocument, index: 0)
        let secondShift = try x(right.logicalDocument, index: 1) - x(left.logicalDocument, index: 1)
        #expect(abs(firstShift + 14.173) < 0.1)
        #expect(abs(secondShift - 14.173) < 0.1)
    }

    @Test("ヘッダーを変えても文書は組み直さず、用紙だけ作り直す")
    func headerComposesOnly() async throws {
        var settings = try settings()
        let renderer = renderer()
        _ = try await renderer.render(source, settings: settings)
        settings.options.furniture = .name
        _ = try await renderer.render(source, settings: settings)
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 2)
    }

    @Test("改ページ・目次・コードの配色・判は、それぞれ文書を組み直す")
    func layoutAxes() async throws {
        var settings = try settings()
        let renderer = renderer()
        _ = try await renderer.prepare(source, settings: settings)
        settings.finish.breaks.h1 = .page
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 2)
        settings.finish.legacyPresetContents.mode = .front
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 3)
        settings.code.block.lineNumbers = .all
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 4)
        settings.layout = .b5Duplex
        _ = try await renderer.prepare(source, settings: settings)
        #expect(renderer.logicalRenderCount == 5)
    }

    @Test("A判へ戻すと A判の大きさで組み直し、目次と改ページはそのまま効く")
    func seriesKeepsFinish() async throws {
        var settings = try settings()
        settings.finish.legacyPresetContents.mode = .front
        settings.finish.breaks.h1 = .rightPage
        var sizes: [CGSize] = []
        let renderer = DocumentRenderer(paginate: { request in
            sizes.append(request.pageSize)
            return try RenderingFixtures.pdf(count: 2, size: request.pageSize)
        })
        let a = try await renderer.prepare(source, settings: settings)
        settings.layout = .b5Duplex
        let b = try await renderer.prepare(source, settings: settings)
        // The stand-in lays every text out on two pages, the contents too.
        #expect(a.addedContentsPages == 2)
        #expect(b.addedContentsPages == 2)
        #expect(sizes.contains(PrintLayout.a4Duplex.logicalPageSize))
        #expect(sizes.contains(PrintLayout.b5Duplex.logicalPageSize))
        let width = try #require(b.logicalDocument.page(at: 0)).bounds(for: .mediaBox).width
        #expect(abs(width - PrintLayout.b5Duplex.logicalPageSize.width) < 1)
    }

    @Test("ヘッダーと改ページと目次と配色と判とノートをまとめて文書の記録に残せる")
    func everyAxisInTheRecord() throws {
        var options = PrintOptions()
        options.furniture = .nameAndDate
        var finish = PrintFinish()
        finish.breaks.h1 = .rightPage
        finish.legacyPresetContents.mode = .front
        var block = CodeBlockOptions()
        block.lineNumbers = .everyFive
        let saved = DocumentSettings(
            layoutID: "b5Duplex", printOptions: options, printFinish: finish, codePaletteID: "ink", codeBlock: block,
            notes: NotePages(isEnabled: true))
        let decoded = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }
}
