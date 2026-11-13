import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PageSourceLifetimeTests {
    // A real appearance stream exercises the CoreGraphics objects that PDFAnnotation.copy reads lazily.
    static func linkedPDF() -> Data {
        let content = "BT /F1 16 Tf 30 450 Td (LINK SOURCE) Tj ET"
        let appearance = "0 0 1 RG 1 1 98 18 re S"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 500] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [30 440 130 460] /A << /S /URI /URI (https://example.com/) >> /AP << /N 7 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 20] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 8\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func plan(numbers: Bool = false) -> ViewPageLayout {
        ViewPageLayout(
            pageCount: 1,
            options: ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: true),
            hasLogicalMargins: false, showsNumbers: numbers)
    }

    @Test("紙を合成した文書はリンクの見た目を持つ元の文書を残し、表示用にコピーできる")
    func composedAnnotationsKeepSource() throws {
        weak var backing: CGPDFDocument?
        let composed = try autoreleasepool {
            let source = try #require(PDFDocument(data: Self.linkedPDF()))
            backing = source.page(at: 0)?.pageRef?.document
            return try #require(PaperComposer.compose(source, paper: nil))
        }
        // Stop before copying if the owner vanished; a regression must fail without crashing the test process.
        try #require(backing != nil)
        let view = try #require(ViewPageDocument.make(composed, plan: plan(), margin: 0))
        let page = try #require(view.page(at: 1))
        #expect(page.string?.contains("LINK SOURCE") == true)
        #expect(page.annotations.first?.url?.absoluteString == "https://example.com/")
        #expect(page.annotations.first?.hasAppearanceStream == true)
    }

    @Test("表示用の写しは元を解放しても再コピーでき、最後の写しとともに元も解放する", arguments: [false, true])
    func viewCopiesKeepSources(numbers: Bool) throws {
        weak var backing: CGPDFDocument?
        weak var sourceDocument: PDFDocument?
        var view: PDFDocument? = try autoreleasepool {
            let source = try #require(PDFDocument(data: Self.linkedPDF()))
            sourceDocument = source
            backing = source.page(at: 0)?.pageRef?.document
            return try #require(ViewPageDocument.make(source, plan: plan(numbers: numbers), margin: 15))
        }
        #expect(sourceDocument == nil)
        try #require(backing != nil)
        try autoreleasepool {
            let page = try #require(view?.page(at: 1))
            let copy = try #require(StandalonePage.copy(of: page))
            #expect(copy.annotations.first?.url?.absoluteString == "https://example.com/")
            #expect(copy.annotations.first?.hasAppearanceStream == true)
        }
        autoreleasepool { view = nil }
        #expect(backing == nil)
    }

    @Test("紙の合成とページのコピーを重ねても注釈の最初の文書まで残す")
    func copiesKeepTransitiveSources() throws {
        weak var backing: CGPDFDocument?
        var page: PDFPage? = try autoreleasepool {
            let source = try #require(PDFDocument(data: Self.linkedPDF()))
            backing = source.page(at: 0)?.pageRef?.document
            let paper = try #require(PaperComposer.compose(source, paper: nil))
            let original = try #require(paper.page(at: 0))
            return try #require(StandalonePage.copy(of: original))
        }
        try #require(backing != nil)
        try autoreleasepool {
            let original = try #require(page)
            let copy = try #require(StandalonePage.copy(of: original))
            #expect(copy.annotations.count == 1)
            #expect(copy.annotations.first?.hasAppearanceStream == true)
            #expect(copy.string?.contains("LINK SOURCE") == true)
        }
        autoreleasepool { page = nil }
        #expect(backing == nil)
    }

    @Test("画像の表示用切り抜きはコピー元の文書を残す")
    func imageCropKeepsSource() throws {
        weak var backing: CGPDFDocument?
        let cropped = try autoreleasepool {
            let source = try RenderingFixtures.pdf()
            backing = source.page(at: 0)?.pageRef?.document
            return ImagePageRenderer.viewDocument(of: source)
        }
        try #require(backing != nil)
        #expect(cropped.page(at: 0)?.string?.contains("PAGE-1") == true)
    }

    @Test("紙の見本はページだけを取り出しても描画元の文書を残す")
    func sampleKeepsSource() throws {
        weak var backing: CGPDFDocument?
        let page = try autoreleasepool {
            let source = try RenderingFixtures.pdf()
            let text = try #require(source.page(at: 0))
            let page = try #require(
                PaperComposer.sample(
                    text: text, paper: nil, pageSize: CGSize(width: 300, height: 500),
                    margins: .uniform(millimeters: 0)))
            backing = page.pageRef?.document
            return page
        }
        try #require(backing != nil)
        #expect(page.string?.contains("PAGE-1") == true)
    }
}
