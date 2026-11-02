import AppKit
import ApplicationServices
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct DuplexTestRendererTests {
    @Test("両面テストは選んだ用紙の縦向き2ページでどちらも回転しない", arguments: [PrintLayout.a4Duplex, .a3BookletA4, .a4BookletA5])
    func pages(layout: PrintLayout) async throws {
        let renderer = DuplexTestRenderer()
        let document = try await renderer.document(
            sheet: layout.sheet,
            labels: .init(
                front: "表", back: "裏", top: "上", binding: "短辺とじ", printer: "Test Printer", instruction: "矢印を確認"))
        #expect(document.pageCount == 2)
        let width = layout.sheet == .a3 ? 841.89 : 595.28
        let height = layout.sheet == .a3 ? 1190.55 : 841.89
        for index in 0..<2 {
            let page = try #require(document.page(at: index))
            #expect(abs(page.bounds(for: .mediaBox).width - width) < 0.01)
            #expect(abs(page.bounds(for: .mediaBox).height - height) < 0.01)
            #expect(page.rotation == 0)
        }
        let testLayout = try renderer.layout(for: layout)
        let info = PrintJobFactory().printInfo(for: testLayout)
        #expect(info.orientation == .portrait)
        #expect(abs(info.paperSize.width - width) < 1)
        #expect(abs(info.paperSize.height - height) < 1)
        var duplex = PMDuplexMode(kPMDuplexNone)
        #expect(PMGetDuplex(OpaquePointer(info.pmPrintSettings()), &duplex) == noErr)
        #expect(duplex == PMDuplexMode(layout == .a4Duplex ? kPMDuplexNoTumble : kPMDuplexTumble))
    }
}
