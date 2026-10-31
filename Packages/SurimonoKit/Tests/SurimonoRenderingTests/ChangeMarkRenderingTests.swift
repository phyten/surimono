import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ChangeMarkRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { font-size: 12pt; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("マークの注釈だけを全ページから取り除き通常のリンクは残す")
    func extractsAndRemoves() throws {
        let document = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 300, height: 500))
        for index in 0..<2 {
            let page = try #require(document.page(at: index))
            let anchor = PDFAnnotation(
                bounds: CGRect(x: 40, y: 80, width: 1, height: 100), forType: .link, withProperties: nil)
            anchor.url = URL(string: "surimono-mark:changed")
            page.addAnnotation(anchor)
            let ordinary = PDFAnnotation(
                bounds: CGRect(x: 80, y: 80, width: 20, height: 10), forType: .link, withProperties: nil)
            ordinary.url = URL(string: "https://example.com")
            page.addAnnotation(ordinary)
        }
        let marks = ChangeMarkAnchors.extract(from: document, requests: [.init(blockID: "changed", isShort: true)])
        #expect(
            marks == [
                ChangeMark(pageIndex: 0, rect: CGRect(x: 40, y: 80, width: 1, height: 100), isShort: true),
                ChangeMark(pageIndex: 1, rect: CGRect(x: 40, y: 80, width: 1, height: 100), isShort: true),
            ])
        let saved = try #require(document.dataRepresentation().flatMap(PDFDocument.init(data:)))
        for index in 0..<2 {
            #expect(saved.page(at: index)?.annotations.count == 1)
            #expect(saved.page(at: index)?.annotations.first?.url?.host == "example.com")
        }
    }

    @Test("マークの有無や面付けの変更だけで印刷の論理ページを組み直さない")
    func printingReusesCache() async throws {
        let text = "Body"
        let id = try #require(MarkdownConverter.convertWithSourceMap(text).blocks.first?.id)
        var calls = 0
        let renderer = DocumentRenderer(paginate: { request in
            calls += 1
            let isGeometryPass = request.preparationScript?.contains("surimono-mark:") == true
            // Deliberately different pagination proves the disposable PDF can never become printable output.
            let document = try RenderingFixtures.pdf(
                count: isGeometryPass ? 3 : 2, size: CGSize(width: 300, height: 500))
            if isGeometryPass {
                let anchor = PDFAnnotation(
                    bounds: CGRect(x: 40, y: 80, width: 1, height: 100), forType: .link, withProperties: nil)
                anchor.url = URL(string: "surimono-mark:\(id)")
                document.page(at: 0)?.addAnnotation(anchor)
            }
            return document
        })
        let source = DocumentSource(data: Data(text.utf8), format: .markdown)
        var marked = settings
        marked.markdownChanges = [.init(blockID: id)]
        let view = try await renderer.render(source, settings: marked)
        #expect(view.changeMarks.count == 1)
        #expect(view.logicalDocument.pageCount == 2)
        #expect(view.sheetDocument.pageCount == 2)
        #expect(view.logicalDocument.page(at: 0)?.annotations.isEmpty == true)
        #expect(view.sheetDocument.page(at: 0)?.annotations.isEmpty == true)
        let printed = try await renderer.render(source, settings: settings)
        #expect(printed.changeMarks.isEmpty)
        #expect(printed.logicalDocument === view.logicalDocument)
        #expect(printed.sheetDocument === view.sheetDocument)
        var duplex = marked
        duplex.layout = .a4Duplex
        _ = try await renderer.render(source, settings: duplex)
        #expect(calls == 2)
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("印刷用にキャッシュした文書へ後から矩形を取得しても論理PDFとシートを交換しない")
    func addsGeometryToCachedPrint() async throws {
        var calls = 0
        let renderer = DocumentRenderer(paginate: { request in
            calls += 1
            let document = try RenderingFixtures.pdf(count: 1)
            if request.preparationScript?.contains("surimono-mark:") == true {
                let anchor = PDFAnnotation(
                    bounds: CGRect(x: 40, y: 80, width: 1, height: 100), forType: .link, withProperties: nil)
                anchor.url = URL(string: "surimono-mark:chosen")
                document.page(at: 0)?.addAnnotation(anchor)
            }
            return document
        })
        let source = DocumentSource(data: Data("Body".utf8), format: .markdown)
        let printed = try await renderer.render(source, settings: settings)
        var marked = settings
        marked.markdownChanges = [.init(blockID: "chosen")]
        let viewed = try await renderer.render(source, settings: marked)
        #expect(calls == 2)
        #expect(viewed.changeMarks.count == 1)
        #expect(viewed.logicalDocument === printed.logicalDocument)
        #expect(viewed.sheetDocument === printed.sheetDocument)
        #expect(renderer.logicalRenderCount == 1)
        #expect(renderer.sheetCompositionCount == 1)
    }

    @Test("HTMLとOrgとLaTeXにはマーク用のアンカーを注入しない", arguments: [DocumentFormat.html, .org, .latex])
    func onlyMarkdown(format: DocumentFormat) async throws {
        let renderer = DocumentRenderer(paginate: { request in
            #expect(request.preparationScript?.contains("surimono-mark:") != true)
            return try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        })
        var marked = settings
        marked.markdownChanges = [.init(blockID: "anything")]
        let output = try await renderer.render(
            DocumentSource(data: Data("Body".utf8), format: format), settings: marked)
        #expect(output.changeMarks.isEmpty)
    }

    @Test("表示用の赤いバーは元のPDFと見開きの補助白紙に入らない")
    func spreadCopyOnly() throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .instant, showsCoverAlone: true)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: false)
        let copy = try #require(
            ViewPageDocument.make(
                source, plan: plan, margin: 40,
                changeMarks: [
                    ChangeMark(pageIndex: 0, rect: CGRect(x: 40, y: 100, width: 1, height: 100))
                ]))
        let marked = try RenderingFixtures.pixel(try #require(copy.page(at: 1)), x: 35, y: 150)
        #expect(marked[0] > 200 && marked[1] < 180 && marked[2] < 170)
        let saved = try #require(copy.dataRepresentation().flatMap(PDFDocument.init(data:)))
        #expect(try RenderingFixtures.pixel(try #require(saved.page(at: 0)), x: 35, y: 150)[1] > 240)
        #expect(try RenderingFixtures.pixel(try #require(source.page(at: 0)), x: 35, y: 150)[1] > 240)
        #expect(copy.page(at: 1)?.string == source.page(at: 0)?.string)
    }

    @Test("結合で左余白を切ったページでは残った左端に短い削除マークを描く")
    func croppedEdge() throws {
        let source = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .horizontal, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 2, options: options, hasLogicalMargins: true, showsNumbers: false)
        let mark = ChangeMark(pageIndex: 1, rect: CGRect(x: 40, y: 100, width: 1, height: 100), isShort: true)
        #expect(
            mark.bar(in: CGRect(x: 40, y: 0, width: 260, height: 500)) == CGRect(x: 40, y: 192, width: 2, height: 8))
        // Given the text area's left edge, bars line up just outside it whatever the block's indent.
        let item = ChangeMark(pageIndex: 0, rect: CGRect(x: 90, y: 100, width: 1, height: 20))
        #expect(
            item.bar(in: CGRect(x: 0, y: 0, width: 300, height: 500), textLeft: 42)
                == CGRect(x: 36, y: 100, width: 2, height: 20))
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 40, changeMarks: [mark]))
        let page = try #require(copy.page(at: 1))
        #expect(page.bounds(for: .cropBox).minX == 40)
        #expect(try RenderingFixtures.pixel(page, x: 41, y: 196)[1] < 180)
        #expect(try RenderingFixtures.pixel(page, x: 41, y: 180)[1] > 240)
    }

    @Test("実際のMarkdown印刷で各ブロックのアンカーは画素を変えず出力から消える", .timeLimit(.minutes(1)))
    func actualPrintLayout() async throws {
        _ = NSApplication.shared
        let text = """
            # Heading

            \(String(repeating: "Long paragraph text. ", count: 500))

            - First
            - Second

            > Quote

            ```swift
            let value = 1
            ```

            | A | B |
            |---|---|
            | a | b |

            ---

            $$
            x + y
            $$

            :::note Title
            Content [^a]
            :::

            [^a]: Footnote
            """
        try await verifyPrintLayout(text: text, expectsMultiplePages: true)
    }

    @Test(
        "罫線だけの文書と表の印も元の画素を変えず取得する", .timeLimit(.minutes(1)),
        arguments: [
            "---", "Before\n\n---", "---\n\nAfter",
            "| A | B |\n|---|---|\n| a | b |",
        ])
    func actualPrintLayoutSpecialBlocks(text: String) async throws {
        _ = NSApplication.shared
        try await verifyPrintLayout(text: text, expectsMultiplePages: false)
    }

    @Test("囲みのタイトルだけの変更でも論理ページと印刷結果は通常組版と一致する", .timeLimit(.minutes(1)))
    func actualPrintLayoutCalloutTitle() async throws {
        _ = NSApplication.shared
        let old = "> [!note] Old\n> Body"
        let text = "> [!note] New\n> Body"
        var marked = settings
        marked.markdownChanges = MarkdownChanges.marks(from: old, to: text)
        #expect(marked.markdownChanges.count == 1)
        let source = DocumentSource(data: Data(text.utf8), format: .markdown)
        let plain = try await DocumentRenderer().render(source, settings: settings)
        let output = try await DocumentRenderer().render(source, settings: marked)
        #expect(!output.changeMarks.isEmpty)
        #expect(try pixelDifferences(plain.logicalDocument, output.logicalDocument).isEmpty)
        #expect(try pixelDifferences(plain.sheetDocument, output.sheetDocument).isEmpty)
    }

    private func verifyPrintLayout(text: String, expectsMultiplePages: Bool) async throws {
        let mapped = MarkdownConverter.convertWithSourceMap(text)
        let ids = Set(mapped.blocks.map(\.id))
        let sourceLines = text.components(separatedBy: "\n")
        let descriptions = Dictionary(
            uniqueKeysWithValues: mapped.blocks.map { block in
                let lines = block.lines.sorted()
                let excerpt = lines.compactMap { sourceLines.indices.contains($0 - 1) ? sourceLines[$0 - 1] : nil }
                    .joined(separator: " / ").prefix(100)
                return (block.id, "\(block.id) lines=\(lines) source=\(excerpt)")
            })
        var found = Set<String>()
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let result = try await WebPaginator().paginateWithResult(
                request.source, pageSize: request.pageSize, margins: request.margins,
                allowsJavaScript: request.allowsJavaScript, preparationScript: request.preparationScript,
                readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground)
            for index in 0..<result.document.pageCount {
                for annotation in result.document.page(at: index)?.annotations ?? [] {
                    if let url = annotation.url, url.scheme == "surimono-mark" {
                        found.insert(String(url.absoluteString.dropFirst("surimono-mark:".count)))
                    }
                }
            }
            return result
        })
        var markedSettings = settings
        markedSettings.markdownChanges = mapped.blocks.map { .init(blockID: $0.id) }
        let source = DocumentSource(data: Data(text.utf8), format: .markdown)
        let plain = try await DocumentRenderer().render(source, settings: settings)
        let marked = try await renderer.render(source, settings: markedSettings)
        for id in ids { #expect(found.contains(id), "Missing anchor: \(descriptions[id] ?? id)") }
        #expect(found.isSubset(of: ids))
        if expectsMultiplePages {
            #expect(marked.logicalDocument.pageCount > 1)
            #expect(marked.changeMarks.contains { $0.pageIndex == 1 })
        }
        #expect(marked.changeMarks.contains { $0.pageIndex == 0 })
        let differences = try pixelDifferences(plain.logicalDocument, marked.logicalDocument)
        if !differences.isEmpty {
            // Only on failure: locate the responsible block without dumping megabytes of pixel arrays.
            var isolated: [String] = []
            for request in markedSettings.markdownChanges {
                var single = settings
                single.markdownChanges = [request]
                let output = try await DocumentRenderer().render(source, settings: single)
                let changed = try pixelDifferences(plain.logicalDocument, output.logicalDocument)
                if !changed.isEmpty {
                    isolated.append(
                        "\(descriptions[request.blockID] ?? request.blockID): \(changed.joined(separator: "; "))")
                }
            }
            #expect(
                differences.isEmpty,
                "Combined: \(differences.joined(separator: "; ")); isolated blocks: \(isolated.joined(separator: " | "))"
            )
        }
        for document in [marked.logicalDocument, marked.sheetDocument] {
            let saved = try #require(document.dataRepresentation().flatMap(PDFDocument.init(data:)))
            for index in 0..<saved.pageCount {
                #expect(saved.page(at: index)?.annotations.contains { $0.url?.scheme == "surimono-mark" } == false)
            }
        }
    }

    /// Bounds use raster coordinates (origin at the top left), making a host failure easy to locate on the page.
    private func pixelDifferences(_ expected: PDFDocument, _ actual: PDFDocument) throws -> [String] {
        var differences: [String] = []
        if expected.pageCount != actual.pageCount {
            differences.append("pageCount=\(expected.pageCount)->\(actual.pageCount)")
        }
        for index in 0..<min(expected.pageCount, actual.pageCount) {
            let before = try #require(expected.page(at: index))
            let after = try #require(actual.page(at: index))
            let a = try pixels(before)
            let b = try pixels(after)
            if a == b { continue }
            let width = Int(ceil(before.bounds(for: .mediaBox).width))
            var count = 0
            var minX = Int.max
            var minY = Int.max
            var maxX = 0
            var maxY = 0
            for offset in stride(from: 0, to: min(a.count, b.count), by: 4)
            where a[offset..<(offset + 4)] != b[offset..<(offset + 4)] {
                let x = offset / 4 % width
                let y = offset / 4 / width
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
            differences.append(
                "page=\(index + 1) pixels=\(count) bounds=(\(minX),\(minY))-(\(maxX),\(maxY)) bytes=\(a.count)->\(b.count) textEqual=\(before.string == after.string)"
            )
        }
        return differences
    }

    private func pixels(_ page: PDFPage) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(try #require(page.pageRef))
        return Array(
            UnsafeBufferPointer(
                start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}
