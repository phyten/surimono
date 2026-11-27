import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PrintedFragmentLinkTests {
    @Test("Org の論理 PDF の目次から英字・日本語・同名の見出しが載る各ページへ移れる", .timeLimit(.minutes(1)))
    func orgPages() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(
            data: Data("#+OPTIONS: toc:t num:t\n* Alpha\n本文A\n* 日本語\n本文B\n* 日本語\n本文C".utf8),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pages.org"), format: .org)
        let settings = RenderSettings(
            layout: .a4Single, theme: .init(id: "test", name: "Test", css: "h1 { break-before: page }"),
            preset: .init(id: "none", name: "None"))
        let document = try await DocumentRenderer().prepare(source, settings: settings).logicalDocument
        let contents = try #require(document.page(at: 0))
        #expect(document.pageCount == 4)
        let links = contents.annotations.filter { $0.type == "Link" }.sorted { $0.bounds.midY > $1.bounds.midY }
        #expect(links.count == 3)
        for (index, link) in links.enumerated() {
            let page = try #require(document.page(at: index + 1))
            let target = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
            #expect(target.page === page)
            #expect(page.bounds(for: .cropBox).contains(target.point))
        }
    }

    @Test("別ページの目次は同じページの同名見出しを区別し、読むための PDF にもその位置を残す", .timeLimit(.minutes(1)))
    func separateContents() async throws {
        let source = DocumentSource(
            data: Data("#+OPTIONS: toc:t num:nil\n* Alpha\n前の本文\n\nAlpha\n\n* Alpha\n次の本文\n* Omega\n最後の本文".utf8),
            format: .org)
        var settings = RenderSettings(
            layout: .a4Single, theme: .init(id: "test", name: "Test", css: "#omega { break-before: page }"),
            preset: .init(id: "none", name: "None"))
        settings.finish.contents.placement = .page
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        #expect(prepared.addedContentsPages == 1)
        let logical = prepared.logicalDocument
        let first = try #require(logical.page(at: 1))
        let last = try #require(logical.page(at: 2))
        let alpha = logical.findString("Alpha").filter { $0.pages.first === first }.map { $0.bounds(for: first) }
        let omega = try #require(logical.findString("Omega").first { $0.pages.first === last }).bounds(for: last)
        // The middle "Alpha" is prose. Only the two heading occurrences have destinations.
        try #require(alpha.count == 3)
        let sourceRows = try #require(logical.page(at: 0)).annotations.sorted { $0.bounds.midY > $1.bounds.midY }
        try #require(sourceRows.count == 3)
        let data = try await ReadingPDFExporter.data(from: logical, entries: [], title: "Contents")
        let saved = try #require(PDFDocument(data: data))
        let savedRows = try #require(saved.page(at: 0)).annotations.sorted { $0.bounds.midY > $1.bounds.midY }
        try #require(savedRows.count == 3)
        for (offset, entry) in [(1, alpha[0]), (1, alpha[2]), (2, omega)].enumerated() {
            let (index, heading) = entry
            let row = sourceRows[offset]
            let target = try #require((row.action as? PDFActionGoTo)?.destination ?? row.destination)
            let page = try #require(logical.page(at: index))
            #expect(target.page === page)
            // The anchor sits at the start of the line box; glyph bounds depend on the font.
            #expect(abs(target.point.y - heading.maxY) < heading.height * 0.6)
            #expect(abs(target.point.x - heading.minX) < heading.height)
            #expect(page.annotations.isEmpty)
            let copy = savedRows[offset]
            let destination = try #require((copy.action as? PDFActionGoTo)?.destination ?? copy.destination)
            let savedPage = try #require(saved.page(at: index))
            #expect(destination.page === savedPage)
            let old = page.bounds(for: .mediaBox)
            let new = savedPage.bounds(for: .mediaBox)
            #expect(abs(target.point.x - old.minX - destination.point.x + new.minX) < 0.02)
            #expect(abs(target.point.y - old.minY - destination.point.y + new.minY) < 0.02)
        }
    }

    @Test("HTML の符号化した断片と名前付きアンカーは本文へ移り、別文書の同名の断片は URL を保つ", .timeLimit(.minutes(1)))
    func htmlFragments() async throws {
        _ = NSApplication.shared
        let html = """
            <!doctype html><meta charset="utf-8">
            <p><a href="#%E7%AF%80">Section</a></p><p><a href="#old">Bookmark</a></p>
            <p><a href="https://example.org/other#old">Other page</a></p>
            <h2 style="break-before:page" id="節">Section</h2><p><a name="old">Bookmark</a></p>
            <p><a href="#">Back</a> <a href="#TOP">Top</a></p>
            """
        let pdf = try await WebPaginator().paginate(
            .snapshot(html, directory: FileManager.default.temporaryDirectory),
            pageSize: CGSize(width: 400, height: 600),
            margins: .uniform(millimeters: 10), allowsJavaScript: false)
        let first = try #require(pdf.page(at: 0))
        let second = try #require(pdf.page(at: 1))
        let destinations = first.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination ?? $0.destination }
        #expect(destinations.count == 2)
        #expect(destinations.allSatisfy { $0.page === second })
        #expect(first.annotations.contains { $0.url?.absoluteString == "https://example.org/other#old" })
        let back = second.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination ?? $0.destination }
        #expect(back.count == 2)
        #expect(back.allSatisfy { $0.page === first })
    }

    @Test("別ページ目次と本文の見出し参照・脚注を同じ Org 文書から書き出せる", .timeLimit(.minutes(1)), arguments: [false, true])
    func separateContentsWithBodyLinks(mirrored: Bool) async throws {
        let renderer = DocumentRenderer()
        let source = DocumentSource(
            data: Data(
                """
                #+OPTIONS: toc:t num:nil
                * First
                See [[#last][next chapter]] and note[fn:1].

                * Last
                :PROPERTIES:
                :CUSTOM_ID: last
                :END:
                End.

                [fn:1] Footnote body
                """.utf8), format: .org)
        var settings = RenderSettings(
            layout: .a4Duplex, theme: .init(id: "test", name: "Test", css: "#last { break-before:page }"),
            preset: .init(id: "none", name: "None"))
        settings.finish.contents.placement = .page
        settings.options.mirrorsMargins = mirrored
        settings.options.margins = .init(top: 12, left: 30, bottom: 12, right: 10)
        let result = try await renderer.prepare(source, settings: settings)
        #expect(result.addedContentsPages == 1)
        let logical = result.logicalDocument
        let saved = try await ReadingPDFExporter.data(from: logical, entries: [], title: "Notes")
        let copy = try #require(PDFDocument(data: saved))
        for pdf in [logical, copy] {
            let front = try #require(pdf.page(at: 0))
            let first = try #require(pdf.page(at: 1))
            let last = try #require(pdf.page(at: 2))
            let bodyLinks = first.annotations.compactMap {
                ($0.action as? PDFActionGoTo)?.destination ?? $0.destination
            }
            try #require(bodyLinks.count == 2)
            for (label, dest) in zip(["Last", "Footnote body"], bodyLinks.sorted { $0.point.y > $1.point.y }) {
                #expect(dest.page === last)
                let line = try RenderingFixtures.searchBounds(
                    label, on: last, in: pdf, stage: pdf === logical ? "logical" : "export")
                #expect(abs(dest.point.y - line.maxY) < 2)
            }
            let rows = front.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination ?? $0.destination }
            #expect(rows.count == 2)
            #expect(rows.contains { $0.page === first })
            #expect(rows.contains { $0.page === last })
        }
    }

    @Test("先頭の注釈をバイト列から除いても後続の本文リンクを書き出せる")
    func removedFirstAnnotation() async throws {
        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        var paper = CGRect(x: 0, y: 2, width: 400, height: 600)
        let rect = CGRect(x: 30, y: 220, width: 100, height: 20)
        context.beginPage(mediaBox: &paper)
        context.setURL(URL(fileURLWithPath: "/unused") as CFURL, for: rect)
        context.setDestination("body" as CFString, for: rect.offsetBy(dx: 0, dy: 40))
        context.endPage()
        context.beginPage(mediaBox: &paper)
        context.addDestination("body" as CFString, at: rect.origin)
        context.endPage()
        context.closePDF()
        let original = try #require(PDFDocument(data: buffer as Data))
        #expect(original.page(at: 0)?.annotations.first?.url?.path == "/unused")
        let bytes = try ReadingPDFNavigationWriter.repair(
            buffer as Data, links: [], bookmarks: nil, removingAnnotations: [0: [0]])
        let document = try #require(PDFDocument(data: bytes))
        let saved = try await ReadingPDFExporter.data(from: document, entries: [], title: "Test")
        let copy = try #require(PDFDocument(data: saved))
        let annotations = try #require(copy.page(at: 0)).annotations
        try #require(annotations.count == 1)
        let target = try #require((annotations[0].action as? PDFActionGoTo)?.destination ?? annotations[0].destination)
        #expect(target.page === copy.page(at: 1))
    }
}
