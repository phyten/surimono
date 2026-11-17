import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFExporterTests {
    @Test("読むPDFは論理ページ順と見出しと外部リンクと題名を保存する", .timeLimit(.minutes(1)))
    func markdown() async throws {
        let source = DocumentSource(
            data: Data(
                """
                # First

                [Example](https://example.com/) [Next](#%E5%9B%B3)

                <div style="break-before: page"></div>

                ## 図

                Text.
                """.utf8),
            fileURL: URL(fileURLWithPath: "/reading-export-fixture/source.md"), format: .markdown)
        let settings = RenderSettings(
            layout: .a4BookletA5,
            theme: PrintTheme(id: "test", name: "Test", css: "body { font-size: 12pt; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let prepared = try await DocumentRenderer().prepare(source, settings: settings)
        let entries = DocumentOutline.entries(
            of: try #require(prepared.facts).headings,
            inPageTexts: (0..<prepared.logicalDocument.pageCount).map {
                prepared.logicalDocument.page(at: $0)?.string ?? ""
            })
        #expect(entries.map(\.pageIndex) == [0, 1])
        let output = try ReadingPDFExporter.document(
            from: prepared.logicalDocument, entries: entries, title: "First",
            headings: try #require(prepared.facts).headings, sourceURL: source.fileURL)
        let bytes = try #require(output.dataRepresentation())
        let reread = try #require(PDFDocument(data: bytes))
        #expect(reread.pageCount == prepared.logicalDocument.pageCount)
        func targets(in document: PDFDocument) -> [Int] {
            (0..<document.pageCount).flatMap { index in
                (document.page(at: index)?.annotations ?? []).compactMap { annotation in
                    let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                    return destination?.page.map { document.index(for: $0) }
                }
            }
        }
        #expect(targets(in: reread).contains(1))
        for index in 0..<reread.pageCount {
            for annotation in try #require(reread.page(at: index)).annotations {
                let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url
                #expect(url?.scheme != "file")
            }
        }

        let first = try #require(reread.outlineRoot?.child(at: 0))
        #expect(first.label == "First")
        #expect(reread.index(for: try #require(first.destination?.page)) == 0)
        let second = try #require(first.child(at: 0))
        #expect(second.label == "図")
        #expect(reread.index(for: try #require(second.destination?.page)) == 1)
        #expect(reread.page(at: 0)?.annotations.contains { $0.url?.absoluteString == "https://example.com/" } == true)
        #expect(reread.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "First")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Surimono")
    }

    @Test("生成した階層しおりと外部リンクは保存して読み直しても残る")
    func generatedOutline() throws {
        let source = try RenderingFixtures.pdf(count: 2)
        let page = try #require(source.page(at: 0))
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/reading")
        page.addAnnotation(link)
        let entries = [
            OutlineEntry(level: 1, title: "First", pageIndex: 0),
            OutlineEntry(level: 3, title: "Second", pageIndex: 1),
        ]
        let output = try ReadingPDFExporter.document(from: source, entries: entries, title: "Reading")
        let bytes = try #require(output.dataRepresentation())
        let reread = try #require(PDFDocument(data: bytes))
        #expect(reread.pageCount == 2)
        let first = try #require(reread.outlineRoot?.child(at: 0))
        let second = try #require(first.child(at: 0))
        #expect(first.label == "First")
        #expect(second.label == "Second")
        #expect(reread.index(for: try #require(first.destination?.page)) == 0)
        #expect(reread.index(for: try #require(second.destination?.page)) == 1)
        #expect(reread.page(at: 0)?.annotations.first?.url?.absoluteString == "https://example.com/reading")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Reading")
        #expect(reread.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "Surimono")
        #expect(source.outlineRoot == nil)
    }

    @Test("元PDFのしおりとページ間リンクを保ち元文書の属性を変更しない")
    func originalPDF() throws {
        let source = try RenderingFixtures.pdf(count: 2)
        let first = try #require(source.page(at: 0))
        let last = try #require(source.page(at: 1))
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Original"
        chapter.destination = PDFDestination(page: last, at: CGPoint(x: 12, y: 150))
        root.insertChild(chapter, at: 0)
        source.outlineRoot = root
        source.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Before", PDFDocumentAttribute.authorAttribute: "Private author",
        ]
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: last, at: CGPoint(x: 0, y: 100)))
        first.addAnnotation(link)
        let output = try ReadingPDFExporter.document(from: source, entries: [], title: "After", preservesOutline: true)
        let bytes = try #require(output.dataRepresentation())
        let reread = try #require(PDFDocument(data: bytes))
        let bookmark = try #require(reread.outlineRoot?.child(at: 0))
        #expect(bookmark.label == "Original")
        #expect(reread.index(for: try #require(bookmark.destination?.page)) == 1)
        let action = try #require(reread.page(at: 0)?.annotations.first?.action as? PDFActionGoTo)
        #expect(reread.index(for: try #require(action.destination.page)) == 1)
        #expect(reread.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Before")
        #expect(source.outlineRoot === root)
    }

    @Test("見出しなしでは空のしおりを付けない")
    func noOutline() throws {
        let output = try ReadingPDFExporter.document(from: RenderingFixtures.pdf(), entries: [], title: "File")
        #expect(output.outlineRoot == nil)
    }

    @Test("生成PDFのローカルURLは削除し元PDFと外部URLは保持する")
    func localLinks() throws {
        let source = try RenderingFixtures.pdf(count: 2)
        let page = try #require(source.page(at: 0))
        let addresses = [
            "file:///private/source.md#%E5%9B%B3", "file:///private/#%E5%9B%B3",
            "surimono-local://document/private/source.md#%E5%9B%B3",
            "file:///private/source.md#missing", "file:///private/other.md#%E5%9B%B3",
            "file:///private/secret.txt", "surimono-local://document/private/secret.txt",
            "https://example.com/#%E5%9B%B3", "mailto:reader@example.com",
            "surimono-snapshot://document/#%E5%9B%B3",
            "surimono-snapshot://document/surimono-snapshot-page.html#%E5%9B%B3",
            "surimono-snapshot://document/other.html#%E5%9B%B3", "about:blank#%E5%9B%B3",
            FileManager.default.temporaryDirectory.appendingPathComponent("surimono-pagination-test.html")
                .absoluteString + "#%E5%9B%B3",
        ]
        for address in addresses {
            let link = PDFAnnotation(
                bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link,
                withProperties: nil)
            link.action = PDFActionURL(url: try #require(URL(string: address)))
            page.addAnnotation(link)
        }
        let output = try ReadingPDFExporter.document(
            from: source, entries: [OutlineEntry(level: 2, title: "図", pageIndex: 1)], title: "Test",
            headings: [DocumentHeading(level: 2, text: "図", id: "図")],
            sourceURL: URL(fileURLWithPath: "/private/source.md"))
        let data = try #require(output.dataRepresentation())
        let reread = try #require(PDFDocument(data: data))
        let links = try #require(reread.page(at: 0)).annotations
        #expect(links.count == 9)
        #expect(links.compactMap { $0.action as? PDFActionGoTo }.count == 7)
        #expect(
            links.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString } == [
                "https://example.com/#%E5%9B%B3", "mailto:reader@example.com",
            ])
        #expect(page.annotations.count == addresses.count)
        let preserved = try ReadingPDFExporter.document(from: source, entries: [], title: "PDF", preservesOutline: true)
        #expect(preserved.page(at: 0)?.annotations.count == addresses.count)
        #expect((preserved.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url?.isFileURL == true)
    }

}
