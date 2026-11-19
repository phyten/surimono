import AppKit
import CoreText
import PDFKit
import Testing

@testable import SurimonoRendering

struct LaTeXContentsLayoutTests {
    @Test("帯の間にある見出しの行き先は次の印刷行のページに載る")
    func anchorsInGaps() {
        typealias Flow = LaTeXFlowLayout
        var first = Flow.Page()
        first.pieces = [.init(slice: .init(strip: 0, start: 0, end: 20, width: 40), x: 0, y: 0, scale: 1)]
        var second = Flow.Page()
        second.pieces = [.init(slice: .init(strip: 0, start: 32, end: 50, width: 40), x: 0, y: 0, scale: 1)]
        let locations = LaTeXFlowPaginator.locations(
            of: [10, 20, 26, 32, 49, 50].enumerated().map {
                .init(index: $0.offset, strip: 0, position: CGFloat($0.element))
            },
            in: [first, second])
        #expect(locations == [0: 0, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1])
    }

    @Test("章末の連続した強制改ページ後は空白を挟まず文献から始まる")
    func consecutiveClearPages() throws {
        typealias Flow = LaTeXFlowLayout
        let items: [Flow.Item] = [
            .init(forced: "clear"), .init(slice: .init(strip: 0, start: 0, end: 20, width: 80)),
            .init(forced: "clear"), .init(forced: "page"), .init(forced: "page"),
            .init(slice: .init(strip: 1, start: 0, end: 20, width: 80)), .init(forced: "clear"),
        ]
        let pages = try Flow.pages(
            .init(
                segments: [.init(columns: 1, gap: 0, rule: 0, balance: false, pageNotes: false, items: items)],
                notes: [:], noteSkip: 0, textFloatSep: 0, floatSep: 0, inTextSep: 0), width: 80, height: 120)
        #expect(pages.map { $0.pieces.map(\.slice.strip) } == [[0], [1]])
    }
    @MainActor @Test("通常印刷でリンク注釈が欠けても計測用の識別子から実ページを読む")
    func markerText() async throws {
        let pdf = try await PDFDrawing.document(pageSize: CGSize(width: 200, height: 100)) { context in
            for text in ["TITLE SRMtestX0Z", "TITLE SRMtestX1Z"] {
                context.beginPDFPage(nil)
                context.textPosition = CGPoint(x: 5, y: 45)
                let line = NSAttributedString(
                    string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)])
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
                context.endPDFPage()
            }
        }
        #expect(LaTeXPageReferences.locations(in: pdf, token: "test", count: 2) == [0: 0, 1: 1])
    }

}
