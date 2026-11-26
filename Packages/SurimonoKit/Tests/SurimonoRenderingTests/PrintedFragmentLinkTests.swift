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

    @Test("組み直した PDF の目印は本文位置への GoTo になり、別文書のリンクは URL を保つ")
    func resolvedAnnotations() async throws {
        let prefix = "surimono-fragment://test/"
        let buffer = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: buffer))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        var paper = CGRect(x: 0, y: 0, width: 400, height: 600)
        let rect = CGRect(x: 30, y: 220, width: 100, height: 20)
        let external = try #require(URL(string: "https://example.org/other#same"))
        context.beginPage(mediaBox: &paper)
        context.setURL(try #require(URL(string: prefix + "link/0")) as CFURL, for: rect)
        context.setURL(external as CFURL, for: rect.offsetBy(dx: 0, dy: 40))
        context.endPage()
        context.beginPage(mediaBox: &paper)
        context.setURL(try #require(URL(string: prefix + "target/0")) as CFURL, for: rect)
        context.endPage()
        context.closePDF()
        let bytes = try await PrintedFragmentLinks(prefix: prefix).resolve(in: buffer as Data)
        let document = try #require(PDFDocument(data: bytes))
        func check(_ pdf: PDFDocument) throws {
            let page = try #require(pdf.page(at: 1))
            let links = try #require(pdf.page(at: 0)).annotations
            #expect(page.annotations.isEmpty)
            #expect(links.count == 2)
            #expect(links.contains { $0.url == external })
            let destinations = links.compactMap { ($0.action as? PDFActionGoTo)?.destination ?? $0.destination }
            let destination = try #require(destinations.first)
            #expect(destination.page === page)
            #expect(destination.point == CGPoint(x: 30, y: 240))
        }
        try check(document)
        let saved = try await ReadingPDFExporter.data(from: document)
        try check(#require(PDFDocument(data: saved)))
    }
}
