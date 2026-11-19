import AppKit
import CoreText
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
                ChangeMark(pageIndex: 0, rect: CGRect(x: 40, y: 80, width: 1, height: 100), isShort: true)
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

    @Test("HTMLにはマーク用のアンカーを注入しない", arguments: [DocumentFormat.html])
    func skipsHTML(format: DocumentFormat) async throws {
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

    @Test("表示用の黄色い背景は元のPDFと見開きの補助白紙に入らない")
    func spreadCopyOnly() throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .instant, showsCoverAlone: true)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: false)
        let copy = try #require(
            ViewPageDocument.make(
                source, plan: plan, margin: 40,
                changeMarks: [
                    ChangeMark(pageIndex: 0, rect: CGRect(x: 40, y: 100, width: 80, height: 100))
                ]))
        let marked = try RenderingFixtures.pixel(try #require(copy.page(at: 1)), x: 55, y: 150)
        #expect(marked[0] > 245 && marked[1] > 230 && (155...180).contains(marked[2]))
        let saved = try #require(copy.dataRepresentation().flatMap(PDFDocument.init(data:)))
        #expect(try RenderingFixtures.pixel(try #require(saved.page(at: 0)), x: 55, y: 150)[1] > 240)
        #expect(try RenderingFixtures.pixel(try #require(source.page(at: 0)), x: 55, y: 150)[1] > 240)
        #expect(copy.page(at: 1)?.string == source.page(at: 0)?.string)
    }

    @Test("削除の印は先頭の短い帯を残し紙の外の部分を切る")
    func croppedEdge() {
        let mark = ChangeMark(pageIndex: 1, rect: CGRect(x: 40, y: 100, width: 80, height: 100), isShort: true)
        #expect(
            mark.highlight(in: CGRect(x: 60, y: 0, width: 260, height: 500))
                == CGRect(x: 60, y: 200, width: 60, height: 3))
    }

    @Test(
        "テーマ対応形式の再読み込みは実際の変換結果から変更したブロックを見つける",
        arguments: [
            DocumentFormat.org, .latex, .plainText, .csv, .asciidoc, .djot, .textile, .mediawiki, .quarto,
            .rMarkdown, .notebook, .docx,
        ])
    func convertedChanges(format: DocumentFormat) async throws {
        func bytes(_ value: String) throws -> Data {
            switch format {
            case .notebook:
                return Data(
                    #"{"nbformat":4,"cells":[{"cell_type":"markdown","source":"\#(value)","metadata":{}}]}"#.utf8)
            case .docx:
                let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                let path =
                    value == "First"
                    ? "../SurimonoFormatsTests/Fixtures/word-structure.docx" : "../../../../Samples/sample.docx"
                return try Data(contentsOf: here.appendingPathComponent(path))
            default: return Data(value.utf8)
            }
        }
        let old = DocumentSource(data: try bytes("First"), format: format)
        let new = DocumentSource(data: try bytes("Edited"), format: format)
        let requests = await DocumentRenderer().changeRequests(from: old, to: new, finish: PrintFinish())
        #expect(requests.contains { !$0.isShort })
        let html = try #require(DocumentRenderer.structureHTML(of: new))
        let mapped = FragmentChanges.identifyingBlocks(in: html, for: requests)
        for request in requests { #expect(mapped.contains("data-surimono-block=\"\(request.blockID)\"")) }
    }

    @Test("後ろのページのテキスト一行とCSVの一行だけに帯が出る")
    func precisePrintedRows() async throws {
        _ = NSApplication.shared
        let lines = (0..<120).map { "Line \($0) body" }.joined(separator: "\n")
        for (format, old, text) in [
            (DocumentFormat.plainText, lines, lines.replacingOccurrences(of: "Line 83 body", with: "Chosen line")),
            (.csv, "Heading,Count\nOne,1\nTwo,2\nThree,3", "Heading,Count\nOne,1\nChosen line,2\nThree,3"),
        ] {
            let source = DocumentSource(data: Data(text.utf8), format: format)
            let renderer = DocumentRenderer()
            var marked = settings
            marked.textScale = 1.25
            marked.markdownChanges = await renderer.changeRequests(
                from: .init(data: Data(old.utf8), format: format),
                to: source, finish: marked.finish)
            let output = try await renderer.prepare(source, settings: marked)
            #expect(output.changeMarks.count == 1)
            let mark = try #require(output.changeMarks.first)
            let page = try #require(output.logicalDocument.page(at: mark.pageIndex))
            let selection = try #require(output.logicalDocument.findString("Chosen line").first)
            let textBox = selection.bounds(for: page)
            #expect(mark.rect.contains(CGPoint(x: textBox.midX, y: textBox.midY)))
            #expect(mark.rect.height < 2.5 * textBox.height)
            if format == .plainText { #expect(mark.pageIndex > 0) }
        }
    }

    @Test("削除位置の帯は隣の文字の外側に置きリストでも本文幅にする")
    func deletionGap() async throws {
        _ = NSApplication.shared
        let text = "First paragraph.\n\n- Neighbour"
        let source = DocumentSource(data: Data(text.utf8), format: .markdown)
        let renderer = DocumentRenderer()
        var marked = settings
        marked.markdownChanges = MarkdownChanges.marks(from: "Other", to: "First paragraph.")
        let first = try await renderer.prepare(source, settings: marked)
        let paragraph = try #require(first.changeMarks.first)
        for old in ["First paragraph.\n\n- Removed\n- Neighbour", text + "\n- Removed"] {
            marked.markdownChanges = MarkdownChanges.marks(from: old, to: text)
            let output = try await renderer.prepare(source, settings: marked)
            let mark = try #require(output.changeMarks.first)
            let page = try #require(output.logicalDocument.page(at: mark.pageIndex))
            let selection = try #require(output.logicalDocument.findString("Neighbour").first)
            let word = selection.bounds(for: page)
            let band = mark.highlight(in: page.bounds(for: .cropBox))
            #expect(mark.isShort)
            #expect(band.height == 3)
            #expect(abs(band.minX - paragraph.rect.minX) <= 1)
            #expect(abs(band.width - paragraph.rect.width) <= 1)
            #expect(old.hasSuffix("Removed") ? band.maxY <= word.minY + 1 : band.minY >= word.maxY - 1)
        }
    }

    @Test("数式の帯は同じ寸法のブロックより下へ二ポイント伸びる")
    func displayMathDepth() async throws {
        _ = NSApplication.shared
        func measured(_ className: String) async throws -> CGRect {
            let html = "<div data-surimono-block='sum' class='\(className)' style='height:40px'>k = 1</div>"
            let pdf = try await WebPaginator().paginate(
                .html(html, baseURL: nil),
                pageSize: CGSize(width: 320, height: 400), margins: .uniform(millimeters: 12), allowsJavaScript: false,
                preparationScript: ChangeMarkAnchors.javaScript([.init(blockID: "sum")]))
            return try #require(ChangeMarkAnchors.extract(from: pdf, requests: [.init(blockID: "sum")]).first).rect
        }
        let plain = try await measured("ordinary")
        let math = try await measured("math-block")
        #expect(abs(plain.maxY - math.maxY) < 0.3)
        #expect(abs(plain.minY - math.minY - 2) < 0.8)
    }

    @Test("文字の印を初回から使い組版済みの紙は色を変えても利用できる")
    func inkWithoutScriptResult() async throws {
        var calls = 0
        var failsOnce = true
        let renderer = DocumentRenderer(paginate: { request in
            calls += 1
            let document = try RenderingFixtures.pdf()
            let script = request.preparationScript ?? ""
            guard script.contains("surimono-mark:") else { return document }
            if script.contains("data-surimono-ink"), failsOnce {
                failsOnce = false
                return document
            }
            let anchor = PDFAnnotation(
                bounds: CGRect(x: 30, y: 720, width: 90, height: 22),
                forType: .link, withProperties: nil)
            anchor.url = URL(string: "surimono-mark:chosen")
            document.page(at: 0)?.addAnnotation(anchor)
            return document
        })
        let source = DocumentSource(data: Data("Words".utf8), format: .org)
        var marked = settings
        marked.markdownChanges = [.init(blockID: "chosen")]
        let plain = try await renderer.prepare(source, settings: marked)
        #expect(plain.changeMarks.first?.textDrawing == nil)
        marked.changeTextHex = "#3399CC"
        let missing = try await renderer.prepare(source, settings: marked)
        #expect(missing.changeMarks.first?.textDrawing == nil)
        let recovered = try await renderer.prepare(source, settings: marked)
        let ink = try #require(recovered.changeMarks.first?.textDrawing)
        let before = calls
        marked.changeTextHex = "#EEFF99"
        let recolored = try await renderer.prepare(source, settings: marked)
        #expect(recolored.changeMarks.first?.textDrawing === ink)
        #expect(recolored.changeMarks.first?.textHex == "#EEFF99")
        marked.changeBackgroundHex = "#AABBCC"
        let background = try await renderer.prepare(source, settings: marked)
        #expect(background.changeMarks.first?.backgroundHex == "#AABBCC")
        #expect(background.changeMarks.first?.textDrawing === ink)
        #expect(calls == before)
        #expect(plain.logicalDocument === recolored.logicalDocument)
    }

    @Test("色をそろえるとPDFの抽出順が変わるコードでも初回と前の位置への編集で文字色を保つ")
    func savesInSyntaxHighlightedCode() async throws {
        _ = NSApplication.shared
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Samples/markdown-features.md")
        let theme = try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
        var marked = settings
        marked.theme = theme
        marked.changeTextHex = "#FF0000"
        let renderer = DocumentRenderer()
        var text = try String(contentsOf: sample, encoding: .utf8)
        for needle in ["星の散歩道\"];", "console.log(books.map(label));", "星の散歩道\"];", "let book =", "struct Book {"] {
            let edited = text.replacingOccurrences(of: needle, with: needle + " 改")
            marked.markdownChanges = MarkdownChanges.marks(from: text, to: edited)
            let output = try await renderer.prepare(.init(data: Data(edited.utf8), format: .markdown), settings: marked)
            let mark = try #require(output.changeMarks.first)
            #expect(mark.textDrawing != nil)
            let plan = ViewPageLayout(
                pageCount: output.logicalDocument.pageCount,
                options: .init(
                    layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false),
                hasLogicalMargins: false, showsNumbers: false)
            let view = try #require(
                ViewPageDocument.make(output.logicalDocument, plan: plan, margin: 0, changeMarks: [mark]))
            let page = try #require(view.page(at: mark.pageIndex))
            let clean = try #require(output.logicalDocument.page(at: mark.pageIndex))
            let screen = try pixels(page)
            let original = try pixels(clean)
            #expect(
                stride(from: 0, to: screen.count, by: 4).contains {
                    screen[$0] > 220 && screen[$0 + 1] < 40 && screen[$0 + 2] < 40
                        && (original[$0] < 180 || original[$0 + 1] > 80)
                })
            #expect(page.string == clean.string)
            text = edited
        }
    }

    @Test("指定した文字色はOrgの変更段落にだけ出て論理ページと用紙には混ざらない", .timeLimit(.minutes(1)))
    func coloredOrgPaper() async throws {
        _ = NSApplication.shared
        let source = DocumentSource(data: Data("First paragraph.\n\nChanged words.".utf8), format: .org)
        let renderer = DocumentRenderer()
        let plain = try await renderer.render(source, settings: settings)
        var marked = settings
        marked.markdownChanges = [.init(blockID: "fragment-1")]
        marked.changeBackgroundHex = "#A8EEFF"
        marked.changeTextHex = "#FF0000"
        let output = try await renderer.render(source, settings: marked)
        let mark = try #require(output.changeMarks.first)
        #expect(mark.rect.width > 10)
        #expect(mark.textDrawing != nil)
        #expect(output.logicalDocument === plain.logicalDocument)
        #expect(output.sheetDocument === plain.sheetDocument)
        let plan = ViewPageLayout(
            pageCount: 1,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false)
        let view = try #require(
            ViewPageDocument.make(output.logicalDocument, plan: plan, margin: 0, changeMarks: [mark]))
        let page = try #require(view.page(at: 0))
        let original = try #require(plain.logicalDocument.page(at: 0))
        #expect(page.string == original.string)
        let colored = try pixels(page)
        let clean = try pixels(original)
        func redPixels(_ bytes: [UInt8]) -> Int {
            stride(from: 0, to: bytes.count, by: 4).count {
                bytes[$0] > 200 && bytes[$0 + 1] < 80 && bytes[$0 + 2] < 80
            }
        }
        #expect(redPixels(colored) > 0)
        #expect(redPixels(clean) == 0)
        let band = try RenderingFixtures.pixel(page, x: Int(mark.rect.maxX - 3), y: Int(mark.rect.midY))
        #expect(abs(Int(band[0]) - 168) <= 2 && abs(Int(band[1]) - 238) <= 2 && band[2] >= 253)
        let unchanged = try #require(page.selection(for: NSRange(location: 0, length: 5))).bounds(for: page)
        let width = Int(ceil(page.bounds(for: .mediaBox).width))
        let height = Int(ceil(page.bounds(for: .mediaBox).height))
        for y in Int(unchanged.minY)..<Int(unchanged.maxY) {
            let start = ((height - 1 - y) * width + Int(unchanged.minX)) * 4
            let end = start + Int(unchanged.width) * 4
            #expect(colored[start..<end] == clean[start..<end])
        }
    }

    @Test("拡大した変更文字の輪郭とタイルの境目に黒い縁が残らず元の文字を選択できる", arguments: [1.5, 5.625, 6.0])
    func inkHasNoDarkFringe(scale: Double) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 360, height: 48)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 245.25, y: 14.125)
        let text = NSAttributedString(string: "Fringe", attributes: [.font: NSFont.systemFont(ofSize: 24)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let original = try #require(PDFDocument(data: data as Data))
        var mark = ChangeMark(pageIndex: 0, rect: box.insetBy(dx: 0.3, dy: 0.2))
        mark.backgroundHex = "#FDF4EF"
        mark.textHex = "#888888"
        mark.textDrawing = ChangeTextDrawing(original)
        let plan = ViewPageLayout(
            pageCount: 1,
            options: .init(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false)
        let copy = try #require(ViewPageDocument.make(original, plan: plan, margin: 0, changeMarks: [mark]))
        let page = try #require(copy.page(at: 0))
        #expect(page.selection(for: box)?.string == "Fringe")
        let bytes = try pixels(page, scale: scale)

        // Each channel of the warm background is lighter than the neutral ink, including at antialiased edges.
        // For neutral sRGB levels 136 and 134 the relative luminances are 0.2462 and 0.2384.
        var minimum = 1.0
        var inkPixels = 0
        let linear = (0...255).map { channel in
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let luminance =
                0.2126 * linear[Int(bytes[i])] + 0.7152 * linear[Int(bytes[i + 1])]
                + 0.0722 * linear[Int(bytes[i + 2])]
            minimum = min(minimum, luminance)
            if abs(Int(bytes[i]) - 136) <= 2 && abs(Int(bytes[i + 1]) - 136) <= 2 && abs(Int(bytes[i + 2]) - 136) <= 2 {
                inkPixels += 1
            }
        }
        #expect(minimum >= linear[136] - 0.008)
        #expect(inkPixels > 100)
    }

    @Test("小数点以下の丸めは許し別の行やページの文字は重ねない")
    func rejectsMovedInk() {
        let box = CGRect(x: 20, y: 200, width: 140, height: 19)
        let clean = ChangeMark(pageIndex: 0, rect: box)
        let neighbour = ChangeMark(pageIndex: 1, rect: box)
        let rounded = ChangeMark(pageIndex: 0, rect: box.offsetBy(dx: 0.01, dy: -0.02))
        let moved = ChangeMark(pageIndex: 1, rect: box.offsetBy(dx: 0, dy: 11))
        #expect(ChangeMarkAnchors.matchingGeometry([clean, neighbour], [rounded, moved]) == [0])
        #expect(ChangeMarkAnchors.matchingGeometry([clean], [neighbour]).isEmpty)
        #expect(
            ChangeMark(pageIndex: 0, rect: box, isShort: true, afterBlock: true)
                .highlight(in: CGRect(x: 0, y: 0, width: 600, height: 800))
                == CGRect(x: 20, y: 197, width: 140, height: 3))
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

    private func pixels(_ page: PDFPage, scale: CGFloat = 1) throws -> [UInt8] {
        let size = page.bounds(for: .mediaBox).size
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(try #require(page.pageRef))
        return Array(
            UnsafeBufferPointer(
                start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}
