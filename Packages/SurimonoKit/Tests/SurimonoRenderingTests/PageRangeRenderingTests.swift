import AppKit
import ApplicationServices
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PageRangeRenderingTests {
    private func settings(_ layout: PrintLayout, range: PageRange = .all) -> RenderSettings {
        var settings = RenderSettings(
            layout: layout, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.pageRange = range
        return settings
    }

    private func pdfSource(count: Int) throws -> DocumentSource {
        DocumentSource(data: try #require(RenderingFixtures.pdf(count: count).dataRepresentation()), format: .pdf)
    }

    private func text(_ document: PDFDocument, _ index: Int) -> String {
        (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("ページの範囲を変えると、組版し直さずに用紙だけを面付けし直す")
    func recomposesOnly() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 12)
        let whole = try await renderer.render(source, settings: settings(.a3BookletA4))
        let part = try await renderer.render(source, settings: settings(.a3BookletA4, range: PageRange([5...12])))
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 2)
        #expect(part.logicalDocument === whole.logicalDocument)
        #expect(whole.sheetDocument.pageCount == 6)
        #expect(part.sheetDocument.pageCount == 4)
        #expect(part.plan.sides.map(\.slots) == [[11, 4], [5, 10], [9, 6], [7, 8]])
        #expect(part.summary.sheetCount == 2)
        #expect(part.summary.logicalPageCount == 8)
        #expect(part.pageSelection.pages == [4, 5, 6, 7, 8, 9, 10, 11])
    }

    @Test("範囲の用紙には選んだページだけが、面付けの順に載る")
    func sheetsHoldSelectedPages() async throws {
        let renderer = DocumentRenderer()
        let result = try await renderer.render(
            try pdfSource(count: 12), settings: settings(.a4Single, range: PageRange([2...2, 7...8])))
        #expect(result.sheetDocument.pageCount == 3)
        #expect(text(result.sheetDocument, 0) == "PAGE-2")
        #expect(text(result.sheetDocument, 1) == "PAGE-7")
        #expect(text(result.sheetDocument, 2) == "PAGE-8")
    }

    @Test("範囲は用紙のキャッシュのキーに入り、戻すと直近の用紙を使い回す")
    func rangeIsPartOfSheetKey() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 6)
        let whole = try await renderer.render(source, settings: settings(.a4Duplex))
        let part = try await renderer.render(source, settings: settings(.a4Duplex, range: PageRange([1...3])))
        #expect(part.sheetDocument !== whole.sheetDocument)
        #expect(part.sheetDocument.pageCount == 4)
        let again = try await renderer.render(source, settings: settings(.a4Duplex))
        #expect(again.sheetDocument === whole.sheetDocument)
        let partAgain = try await renderer.render(source, settings: settings(.a4Duplex, range: PageRange([1...3])))
        #expect(partAgain.sheetDocument === part.sheetDocument)
        #expect(renderer.sheetCompositionCount == 2)
    }

    @Test("全ページを覆う範囲は、範囲なしの用紙をそのまま使う")
    func coveringRangeSharesSheets() async throws {
        let renderer = DocumentRenderer()
        let source = try pdfSource(count: 4)
        let whole = try await renderer.render(source, settings: settings(.a4Single))
        let covering = try await renderer.render(source, settings: settings(.a4Single, range: PageRange([1...9])))
        #expect(covering.sheetDocument === whole.sheetDocument)
        #expect(renderer.sheetCompositionCount == 1)
    }

    @Test("文書が短くなって範囲に何も残らなければ全ページを刷り、ないことを伝える")
    func emptyRangePrintsEverything() async throws {
        let renderer = DocumentRenderer()
        let result = try await renderer.render(
            try pdfSource(count: 3), settings: settings(.a4Single, range: PageRange([5...12])))
        #expect(result.sheetDocument.pageCount == 3)
        #expect(result.pageSelection == PageRange.Selection(pages: nil, isOutOfDocument: true))
    }

    @Test("範囲を刷っても、ヘッダーとフッターの番号と総数は文書のままにする")
    func furnitureKeepsRealNumbers() async throws {
        let source = try RenderingFixtures.pdf(count: 12, size: PaperSize.a4.size)
        var options = PrintOptions()
        options.furniture = .name
        let output = try await PDFComposer().compose(
            source, layout: .a4Single, options: options, furniture: PageFurniture.Context(fileName: "doc"),
            pages: [4])
        #expect(output.pageCount == 1)
        let page = try #require(output.page(at: 0))
        let footer = try #require(page.selection(for: CGRect(x: 0, y: 0, width: 595, height: 42))?.string)
        #expect(footer.trimmingCharacters(in: .whitespacesAndNewlines) == "5 / 12")
    }

    @Test("画像の束の範囲は、並び順のページを数える")
    func imageBundle() async throws {
        let images = try (1...4).map { index in
            DocumentSource.Image(
                data: try RenderingFixtures.image(), fileURL: URL(fileURLWithPath: "/fixtures/\(index).tiff"))
        }
        let renderer = DocumentRenderer()
        let result = try await renderer.render(
            .images(images), settings: settings(.a3TwoUp, range: PageRange([2...4])))
        #expect(result.plan.sides.map(\.slots) == [[1, 2], [3, nil]])
        #expect(result.sheetDocument.pageCount == 2)
    }

    @Test("部数は印刷設定に入り、部単位で出る")
    func copies() {
        let info = PrintJobFactory().printInfo(for: .a4Duplex, copies: 3)
        #expect(info.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int == 3)
        var collates: DarwinBoolean = false
        #expect(PMGetCollate(OpaquePointer(info.pmPrintSettings()), &collates) == noErr)
        #expect(collates.boolValue)
    }

    @Test("部数を渡さなければ 1 部で、前の印刷の部数を引き継がない")
    func oneCopyByDefault() {
        let base = NSPrintInfo()
        base.dictionary()[NSPrintInfo.AttributeKey.copies] = 5
        let info = PrintJobFactory().printInfo(for: .a4Single, base: base)
        #expect(info.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int == 1)
    }

    @Test("部数は 1 から 99 に収める")
    func copiesAreClamped() {
        let many = PrintJobFactory().printInfo(for: .a4Single, copies: 500)
        #expect(many.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int == 99)
        let none = PrintJobFactory().printInfo(for: .a4Single, copies: 0)
        #expect(none.dictionary()[NSPrintInfo.AttributeKey.copies] as? Int == 1)
    }
}
