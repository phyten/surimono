import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct SheetCompositionTests {
    private func settings(_ layout: PrintLayout) -> RenderSettings {
        RenderSettings(
            layout: layout, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    private func pdfSource(count: Int) throws -> DocumentSource {
        DocumentSource(data: try #require(RenderingFixtures.pdf(count: count).dataRepresentation()), format: .pdf)
    }

    @Test("論理ページは用紙の面付けを待たずに用意される")
    func preparesWithoutComposing() async throws {
        let renderer = DocumentRenderer()
        let prepared = try await renderer.prepare(try pdfSource(count: 5), settings: settings(.a4Single))
        #expect(prepared.logicalDocument.pageCount == 5)
        #expect(renderer.sheetCompositionCount == 0)
        let result = try await renderer.composeSheet(for: prepared)
        #expect(result.id == prepared.id)
        #expect(result.sheetDocument.pageCount == 5)
        #expect(renderer.sheetCompositionCount == 1)
    }

    @Test("論理ページの入力が同じなら、面付けの設定を変えても同じ論理 PDF を返す")
    func keepsLogicalDocument() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 4)
        var settings = settings(.a4Single)
        let first = try await renderer.prepare(source, settings: settings)
        settings.options.showsPageNumbers = true
        settings.layout = .a3BookletA4
        let second = try await renderer.prepare(source, settings: settings)
        #expect(second.logicalDocument === first.logicalDocument)
        #expect(second.id != first.id)
    }

    @Test("面付けに効く設定を変えると面付けし直し、戻すと直近の用紙を使い回す")
    func recomposesWhenSheetSettingsChange() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 4)
        var settings = settings(.a4Duplex)
        let plain = try await renderer.render(source, settings: settings)
        settings.options.showsPageNumbers = true
        let numbered = try await renderer.render(source, settings: settings)
        #expect(renderer.sheetCompositionCount == 2)
        #expect(numbered.sheetDocument !== plain.sheetDocument)
        #expect(numbered.sheetDocument.string?.contains("3") == true)
        settings.options.showsPageNumbers = false
        let again = try await renderer.render(source, settings: settings)
        #expect(renderer.sheetCompositionCount == 2)
        #expect(again.sheetDocument === plain.sheetDocument)
    }

    @Test("本文が変わったら、同じ設定でも前の本文の用紙を使わない")
    func doesNotReuseSheetsOfOtherPages() async throws {
        let renderer = DocumentRenderer()
        let settings = settings(.a4Single)
        let three = try await renderer.render(try pdfSource(count: 3), settings: settings)
        let two = try await renderer.render(try pdfSource(count: 2), settings: settings)
        #expect(three.sheetDocument.pageCount == 3)
        #expect(two.sheetDocument.pageCount == 2)
        #expect(renderer.sheetCompositionCount == 2)
    }

    @Test("キャッシュを消すと、同じ本文と設定でも面付けし直す")
    func clearCacheDropsSheets() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 2)
        let first = try await renderer.render(source, settings: settings(.a4Single))
        renderer.clearCache()
        let second = try await renderer.render(source, settings: settings(.a4Single))
        #expect(renderer.sheetCompositionCount == 2)
        #expect(second.logicalDocument !== first.logicalDocument)
    }

    @Test(
        "使い回した論理ページから作る用紙は、論理 PDF をそのまま面付けした用紙と同じになる",
        arguments: [PrintLayout.a4Single, .a4Duplex, .a3BookletA4, .a4BookletA5])
    func sheetsMatchDirectComposition(layout: PrintLayout) async throws {
        let renderer = DocumentRenderer()
        // Mixed shapes, a crop box away from the origin and a rotated page exercise the drawing transform.
        let pdf = try RenderingFixtures.pdf(count: 4, size: CGSize(width: 300, height: 420))
        let wide = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 420, height: 300))
        pdf.insert(try #require(wide.page(at: 0)), at: 2)
        try #require(pdf.page(at: 1)).setBounds(CGRect(x: 20, y: 30, width: 200, height: 300), for: .cropBox)
        try #require(pdf.page(at: 3)).rotation = 90
        let source = DocumentSource(data: try #require(pdf.dataRepresentation()), format: .pdf)
        var settings = settings(layout)
        settings.options.showsPageNumbers = true
        settings.options.rotatesBackSides = true
        // The first composition serializes the logical pages; the second reuses them.
        _ = try await renderer.render(source, settings: settings)
        settings.options.marginsInMillimeters += 1
        let result = try await renderer.render(source, settings: settings)
        let direct = try await PDFComposer().compose(
            result.logicalDocument, layout: result.layout, options: settings.options,
            orientsEachPage: layout.kind == .normal && layout.duplex == .none)
        #expect(result.sheetDocument.pageCount == direct.pageCount)
        for index in 0..<direct.pageCount {
            let page = try #require(result.sheetDocument.page(at: index))
            let expected = try #require(direct.page(at: index))
            #expect(page.bounds(for: .mediaBox) == expected.bounds(for: .mediaBox))
            #expect(try bitmap(page) == bitmap(expected))
        }
        #expect(result.sheetOrientations.count == direct.pageCount)
    }

    private func bitmap(_ page: PDFPage) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width / 2))
        let height = Int(ceil(size.height / 2))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        context.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
    }
}
