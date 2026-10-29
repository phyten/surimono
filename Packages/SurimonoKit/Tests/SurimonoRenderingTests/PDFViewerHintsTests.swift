import CoreGraphics
import Foundation
import PDFKit
import SurimonoRendering
import Testing

@MainActor
struct PDFViewerHintsTests {
    @Test("カタログのページ配置と閲覧方向の名前を読む")
    func bothHints() throws {
        let document = try pdf(catalog: "/PageLayout /TwoPageRight /ViewerPreferences << /Direction /R2L >>")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: "TwoPageRight", direction: "R2L"))
    }

    @Test("カタログにヒントがなければ両方ともnilになる")
    func noHints() throws {
        let document = try pdf(catalog: "")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: nil, direction: nil))
    }

    @Test("ページ配置が名前型でなければ方向だけを読む")
    func nonNameLayout() throws {
        let document = try pdf(catalog: "/PageLayout (TwoPageRight) /ViewerPreferences << /Direction /R2L >>")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: nil, direction: "R2L"))
    }

    @Test("閲覧設定が辞書でなければページ配置だけを読む")
    func nonDictionaryPreferences() throws {
        let document = try pdf(catalog: "/PageLayout /SinglePage /ViewerPreferences (R2L)")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: "SinglePage", direction: nil))
    }

    @Test("閲覧方向が名前型でなければnilになる")
    func nonNameDirection() throws {
        let document = try pdf(catalog: "/PageLayout /OneColumn /ViewerPreferences << /Direction (R2L) >>")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: "OneColumn", direction: nil))
    }

    @Test("空の閲覧設定辞書では方向がnilになる")
    func emptyPreferences() throws {
        let document = try pdf(catalog: "/PageLayout /TwoPageLeft /ViewerPreferences << >>")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: "TwoPageLeft", direction: nil))
    }

    @Test("左から右の方向名もそのまま返す")
    func leftToRight() throws {
        let document = try pdf(catalog: "/ViewerPreferences << /Direction /L2R >>")
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: nil, direction: "L2R"))
    }

    @Test("未知の名前も解釈せず呼び出し側へ渡す")
    func unknownNames() throws {
        let document = try pdf(
            catalog: "/PageLayout /FutureLayout /ViewerPreferences << /Direction /FutureDirection >>")
        #expect(
            PDFViewerHints.read(from: document)
                == PDFViewerHints(pageLayout: "FutureLayout", direction: "FutureDirection"))
    }

    @Test("CoreGraphicsで生成したヒントのないPDFでは両方ともnilになる")
    func generatedPDF() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        #expect(PDFViewerHints.read(from: document) == PDFViewerHints(pageLayout: nil, direction: nil))
    }

    @Test("読み取り元のない新規PDFDocumentでは両方ともnilになる")
    func emptyDocument() {
        #expect(PDFViewerHints.read(from: PDFDocument()) == PDFViewerHints(pageLayout: nil, direction: nil))
    }

    private func pdf(catalog: String) throws -> PDFDocument {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R \(catalog) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xrefOffset = data.count
        data.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        return document
    }
}
