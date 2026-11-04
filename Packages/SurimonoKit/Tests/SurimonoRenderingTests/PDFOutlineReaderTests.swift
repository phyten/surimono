import CoreGraphics
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@Suite("PDF のしおり")
struct PDFOutlineReaderTests {
    private func document(pages: Int) throws -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
            document.insert(page, at: index)
        }
        return document
    }

    private func outline(_ label: String, to page: PDFPage?) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = label
        if let page { outline.destination = PDFDestination(page: page, at: .zero) }
        return outline
    }

    @Test("しおりを階層の深さとページつきで読む")
    func readsNestedOutline() throws {
        let document = try document(pages: 3)
        let root = PDFOutline()
        let chapter = outline("第一章", to: document.page(at: 1))
        chapter.insertChild(outline("節", to: document.page(at: 2)), at: 0)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        #expect(
            PDFOutlineReader.entries(of: document) == [
                OutlineEntry(level: 1, title: "第一章", pageIndex: 1), OutlineEntry(level: 2, title: "節", pageIndex: 2),
            ])
    }

    @Test("しおりのない PDF には目次がない")
    func noOutline() throws {
        #expect(PDFOutlineReader.entries(of: try document(pages: 2)).isEmpty)
    }

    @Test("Markdown の見出しは組版の前の HTML から読める")
    func structureHTMLOfMarkdown() throws {
        let html = try #require(
            DocumentRenderer.structureHTML(of: DocumentSource(data: Data("# 見出し\n\n本文".utf8), format: .markdown)))
        #expect(DocumentOutline.headings(inHTML: html).map(\.text) == ["見出し"])
    }

    @Test("PDF には組版の前の HTML がない")
    func structureHTMLOfPDF() {
        #expect(DocumentRenderer.structureHTML(of: DocumentSource(data: Data(), format: .pdf)) == nil)
    }
}
