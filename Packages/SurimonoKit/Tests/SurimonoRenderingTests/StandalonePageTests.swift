import PDFKit
import SurimonoRendering
import Testing

@MainActor
struct StandalonePageTests {
    @Test("一時的な文書から取り出したページは、描いた元の文書をページと一緒に残す（アクセシビリティが元の文書を読むため）")
    func pageKeepsItsSource() throws {
        let data = try #require(
            RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500)).dataRepresentation())
        weak var source: CGPDFDocument?
        let page = try autoreleasepool { () throws -> PDFPage in
            let page = try #require(StandalonePage.first(of: data))
            source = page.pageRef?.document
            let other = PDFDocument()
            other.insert(page, at: 0)
            return page
        }
        #expect(source != nil)
        #expect(page.pageRef?.document === source)
    }

    @Test("取り出したページを手放せば、ページも元の文書も解放する", arguments: [false, true])
    func releasedWithThePage(inserted: Bool) throws {
        let data = try #require(
            RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500)).dataRepresentation())
        weak var page: PDFPage?
        weak var source: CGPDFDocument?
        weak var temporary: PDFDocument?
        try autoreleasepool {
            let document = try #require(PDFDocument(data: data))
            temporary = document
            let taken = try #require(StandalonePage.first(of: document))
            page = taken
            source = taken.pageRef?.document
            if inserted { PDFDocument().insert(taken, at: 0) }
        }
        #expect(temporary == nil)
        #expect(page == nil)
        #expect(source == nil)
    }
}
