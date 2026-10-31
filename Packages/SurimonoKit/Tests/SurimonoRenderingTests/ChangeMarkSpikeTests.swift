import AppKit
import PDFKit
import Testing

@testable import SurimonoRendering

/// Feasibility gate: link geometry must come from the actual print operation, without changing its pixels.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChangeMarkSpikeTests {
    @Test("空の絶対配置リンクは改ページの両側に矩形を残し画素を変えず除去できる")
    func fragmentedAnchor() async throws {
        _ = NSApplication.shared
        let anchor = """
            <a href="surimono-mark:block" style="position:absolute;top:0;bottom:0;left:0;width:1px"></a>
            """
        func html(marked: Bool) -> String {
            """
            <!doctype html><meta charset="utf-8"><style>
            body { margin:0; font:16px/24px Helvetica; }
            p { margin:0; orphans:1; widows:1; }
            </style><body><p style="\(marked ? "position:relative" : "")">
            \(marked ? anchor : "")\((1...90).map { "Line \($0)<br>" }.joined())
            </p></body>
            """
        }
        let paginator = WebPaginator()
        let plain = try await paginator.paginate(
            .html(html(marked: false), baseURL: nil), pageSize: CGSize(width: 400, height: 500),
            margins: .uniform(millimeters: 15), allowsJavaScript: false)
        let marked = try await paginator.paginate(
            .html(html(marked: true), baseURL: nil), pageSize: CGSize(width: 400, height: 500),
            margins: .uniform(millimeters: 15), allowsJavaScript: false)
        #expect(plain.pageCount > 1)
        #expect(marked.pageCount == plain.pageCount)
        for index in 0..<plain.pageCount {
            let expected = try #require(plain.page(at: index))
            let page = try #require(marked.page(at: index))
            let annotations = page.annotations.filter { $0.url?.scheme == "surimono-mark" }
            #expect(!annotations.isEmpty, "Page \(index) must contain the block fragment")
            for annotation in annotations {
                #expect(annotation.bounds.height > 10)
                #expect(page.bounds(for: .mediaBox).intersects(annotation.bounds))
                page.removeAnnotation(annotation)
            }
            #expect(try bitmap(page) == bitmap(expected), "Page \(index) must be pixel-identical")
        }
        let saved = try #require(marked.dataRepresentation().flatMap(PDFDocument.init(data:)))
        for index in 0..<saved.pageCount {
            #expect(saved.page(at: index)?.annotations.contains { $0.url?.scheme == "surimono-mark" } == false)
        }
    }

    private func bitmap(_ page: PDFPage) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
    }
}
