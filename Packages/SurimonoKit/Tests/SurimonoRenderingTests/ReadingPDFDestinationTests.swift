import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFDestinationTests {
    // Use independent PDF objects: PDFKit cannot author FitR and can lose a GoTo on write.
    private func file(
        link: String = "/Dest /left", bookmark: String = "/Dest (region)", open: Bool = false,
        mediaBox: String = "0 0 200 300", rect: String? = "10 10 20 20"
    ) -> Data {
        let annotations = rect == nil ? "" : "/Annots [4 0 R]"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R /Dests << /left [3 0 R /FitH null] >> /Names << /Dests << /Kids [10 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] /Resources << >> \(annotations) >>",
            "<< /Type /Annot /Subtype /Link /Rect [\(rect ?? "")] \(link) >>",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count \(open ? 4 : 1) >>",
            "<< /Title (Parent) /Parent 5 0 R /First 7 0 R /Last 8 0 R /Count \(open ? 3 : -3) >>",
            "<< /Title (Branch) /Parent 6 0 R /Next 8 0 R /First 9 0 R /Last 9 0 R /Count 1 >>",
            "<< /Title (Tail) /Parent 6 0 R /Prev 7 0 R /Dest [3 0 R /Fit] >>",
            "<< /Title (Leaf) /Parent 7 0 R \(bookmark) >>",
            "<< /Limits [(region) (region)] /Names [(region) << /D [3 0 R /FitR 21 32 104 205] >>] >>",
        ]
        return pdf(objects)
    }

    private func pdf(_ objects: [String]) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let start = data.count
        data.append(contentsOf: "xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            data.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        data.append(
            contentsOf: "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF"
                .utf8)
        return data
    }

    // The two pages have different horizontal origins so a link cannot use its own page's offset for its target.
    private func offsetPages() -> Data {
        pdf([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [11 2.000036 211 302] /Resources << >> /Annots [5 0 R 6 0 R 9 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [7 2.000036 207 302] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [21 40 51 50] /Dest [4 0 R /XYZ 64 102 1.5] >>",
            "<< /Type /Annot /Subtype /Link /Rect [31 60 71 72] /Dest [4 0 R /FitH 162] >>",
            "<< /Type /Outlines /Count 1 /First 8 0 R /Last 8 0 R >>",
            "<< /Title (Region) /Parent 7 0 R /Dest [4 0 R /FitR 17 22 107 202] >>",
            "<< /Type /Annot /Subtype /Link /Rect [41 80 61 90] /A << /S /URI /URI (file:///paper.tex#section) >> >>",
        ])
    }

    @Test("柱を付けて複製しても、リンクの領域とリンク・しおりの行先は用紙内の同じ位置に残る", arguments: [true, false])
    func offsetPageNavigation(preservesOutline: Bool) async throws {
        let source = try #require(PDFDocument(data: offsetPages()))
        var options = PrintOptions()
        options.furniture = .name
        let placement = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 2, layout: .a4Single, options: options,
                context: .init(fileName: "Paper.tex")))
        let bytes = try await ReadingPDFExporter.data(
            from: source, entries: [.init(level: 1, title: "Section", pageIndex: 1)], title: "Paper",
            preservesOutline: preservesOutline, headings: [.init(level: 1, text: "Section", id: "section")],
            sourceURL: URL(fileURLWithPath: "/paper.tex"), furniture: [0: placement])
        let saved = try #require(PDFDocument(data: bytes))
        let first = try #require(saved.page(at: 0)).bounds(for: .mediaBox)
        let second = try #require(saved.page(at: 1)).bounds(for: .mediaBox)
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        let rectangles = [
            CGRect(x: 10, y: 37.999964, width: 30, height: 10),
            CGRect(x: 20, y: 57.999964, width: 40, height: 12),
            CGRect(x: 30, y: 77.999964, width: 20, height: 10),
        ]
        try #require(raw.links.count == rectangles.count)
        for (link, rect) in zip(raw.links, rectangles) {
            #expect(link.page == 0)
            #expect(abs(link.bounds.minX - first.minX - rect.minX) < 0.01)
            #expect(abs(link.bounds.minY - first.minY - rect.minY) < 0.01)
            #expect(abs(link.bounds.width - rect.width) < 0.01)
            #expect(abs(link.bounds.height - rect.height) < 0.01)
        }
        let xyz = try #require(raw.links[0].action.target)
        try #require(xyz.mode == "XYZ" && xyz.page == 1)
        #expect(abs(try #require(xyz.arguments[0]) - second.minX - 57) < 0.01)
        #expect(abs(try #require(xyz.arguments[1]) - second.minY - 99.999964) < 0.01)
        #expect(xyz.arguments[2] == 1.5)
        let fit = try #require(raw.links[1].action.target)
        try #require(fit.mode == "FitH" && fit.page == 1)
        #expect(abs(try #require(fit.arguments[0]) - second.minY - 159.999964) < 0.01)

        try #require(raw.outline.count == 1)
        let bookmark = try #require(raw.outline[0].action.target)
        #expect(bookmark.page == 1)
        if preservesOutline {
            #expect(raw.links[2].action == .other)
            try #require(bookmark.mode == "FitR")
            #expect(abs(try #require(bookmark.arguments[0]) - second.minX - 10) < 0.01)
            #expect(abs(try #require(bookmark.arguments[1]) - second.minY - 19.999964) < 0.01)
            #expect(abs(try #require(bookmark.arguments[2]) - second.minX - 100) < 0.01)
            #expect(abs(try #require(bookmark.arguments[3]) - second.minY - 199.999964) < 0.01)
        } else {
            #expect(raw.links[2].action.target == bookmark)
            try #require(bookmark.mode == "XYZ")
            #expect(abs(try #require(bookmark.arguments[0]) - second.minX) < 0.01)
            #expect(abs(try #require(bookmark.arguments[1]) - second.maxY) < 0.01)
        }
    }

    private func markedPages(rotated: Bool) -> Data {
        func stream(_ commands: String) -> String {
            "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream"
        }
        return pdf([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            """
            << /Type /Page /Parent 2 0 R /MediaBox [11 13 171 213] /CropBox [17 21 155 191]
            /Rotate \(rotated ? 90 : 0) /Resources << >> /Contents 5 0 R /Annots [7 0 R] >>
            """,
            """
            << /Type /Page /Parent 2 0 R /MediaBox [7 29 167 229] /CropBox [19 33 151 207]
            /Rotate \(rotated ? 270 : 0) /Resources << >> /Contents 6 0 R >>
            """,
            stream("1 0 0 rg 41 53 18 10 re f"), stream("1 0 0 rg 66 107 8 6 re f"),
            "<< /Type /Annot /Subtype /Link /Rect [41 53 59 63] /Border [0 0 0] /Dest [4 0 R /XYZ 70 110 1] >>",
        ])
    }

    // Rasterize just the content stream in default user space. Only the red mark contributes to its bounds,
    // even when the exporter draws a footer on the same page.
    private func markOnPaper(_ page: PDFPage) throws -> CGRect {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width)
        let height = Int(box.height)
        let bitmap = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bitmap.translateBy(x: -box.minX, y: -box.minY)
        bitmap.drawPDFPage(try #require(page.pageRef))
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var ink = CGRect.null
        for row in 0..<height {
            for x in 0..<width {
                let i = (row * width + x) * 4
                if pixels[i] > 200 && pixels[i + 1] < 50 && pixels[i + 2] < 50 {
                    ink = ink.union(CGRect(x: x, y: height - row - 1, width: 1, height: 1))
                }
            }
        }
        try #require(!ink.isNull)
        return ink
    }

    private func checkMarkedLink(_ document: PDFDocument, from index: Int) throws {
        let source = try #require(document.page(at: index))
        let target = try #require(document.page(at: index + 1))
        let mark = try markOnPaper(source)
        let landing = try markOnPaper(target)
        #expect(mark == CGRect(x: 30, y: 40, width: 18, height: 10))
        #expect(landing == CGRect(x: 59, y: 78, width: 8, height: 6))

        let annotation = try #require(source.annotations.first)
        let sourceBox = source.bounds(for: .mediaBox)
        #expect(annotation.bounds.offsetBy(dx: -sourceBox.minX, dy: -sourceBox.minY) == mark)
        let destination = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
        #expect(destination.page === target)
        let targetBox = target.bounds(for: .mediaBox)
        #expect(destination.point.x - targetBox.minX == landing.midX)
        #expect(destination.point.y - targetBox.minY == landing.midY)
    }

    @Test("表示範囲が用紙と異なるページを複製しても、回転と縦横の原点差によらずリンクが本文の目印に重なる", arguments: [false, true])
    func exportedMarks(rotated: Bool) async throws {
        let original = try #require(PDFDocument(data: markedPages(rotated: rotated)))
        try checkMarkedLink(original, from: 0)
        var options = PrintOptions()
        options.furniture = .name
        let footer = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 2, layout: .a4Single, options: options,
                context: .init(fileName: "Marks.pdf")))
        let bytes = try await ReadingPDFExporter.data(
            from: original, entries: [], title: "Marks", preservesOutline: true, furniture: [0: footer])
        let saved = try #require(PDFDocument(data: bytes))
        try checkMarkedLink(saved, from: 0)
        for i in 0..<2 {
            let before = try #require(original.page(at: i))
            let after = try #require(saved.page(at: i))
            #expect(after.rotation == before.rotation)
            let crop = before.bounds(for: .cropBox)
            let media = before.bounds(for: .mediaBox)
            let savedMedia = after.bounds(for: .mediaBox)
            #expect(
                after.bounds(for: .cropBox).offsetBy(dx: -savedMedia.minX, dy: -savedMedia.minY)
                    == crop.offsetBy(dx: -media.minX, dy: -media.minY))
        }
    }

    @Test("別の PDF を前にとじても、元文書のリンクが合本内の正しいページの目印を指す")
    func boundMarks() async throws {
        let children = [
            DocumentSource(data: try RenderingFixtures.pdfData(count: 1), format: .pdf),
            DocumentSource(data: markedPages(rotated: false), format: .pdf),
        ]
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.binderStartsOnFront = false
        let binder = try await DocumentRenderer().prepare(.binder(children), settings: settings)
        let bytes = try await ReadingPDFExporter.data(from: binder.viewDocument, entries: [], title: "Binder")
        let saved = try #require(PDFDocument(data: bytes))
        try #require(saved.pageCount == 3)
        try checkMarkedLink(saved, from: 1)
    }

    @Test("合本の表示用 PDF で、二つ目の文書のリンクがその文書の目印に着地する")
    func boundViewMarks() async throws {
        let children = [
            DocumentSource(data: try RenderingFixtures.pdfData(count: 1), format: .pdf),
            DocumentSource(data: markedPages(rotated: false), format: .pdf),
        ]
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.binderStartsOnFront = false
        let prepared = try await DocumentRenderer().prepare(.binder(children), settings: settings)
        try #require(prepared.viewDocument.pageCount == 3)
        try checkMarkedLink(prepared.viewDocument, from: 1)

        // Exercise the Sequoia write and reopen even on systems where prepare can return the assembled pages.
        let reopened = try await StandalonePage.reopenBinder(prepared.viewDocument)
        try checkMarkedLink(reopened, from: 1)
        let first = try #require(reopened.page(at: 0))
        let selection = try #require(first.selection(for: NSRange(location: 0, length: first.numberOfCharacters)))
        #expect(selection.pages.first === first)
        #expect(selection.string?.contains("PAGE-1") == true)
    }

    @Test("同じ子を二度とじても、同じ矩形の内部リンク・URL・メモを区別し、宛先の表示方法を保つ", arguments: [false, true])
    func repeatedChildLinks(named: Bool) async throws {
        // PDFKit may read the name tree while returning no page for a legacy name in the same catalog.
        let horizontal = "[4 0 R /FitH null]"
        let region = "[4 0 R /FitR 21 32 104 205]"
        let xyz = "[4 0 R /XYZ 73 null 1.5]"
        let rect = "/Rect [10 10 34 34]"
        let child = DocumentSource(
            data: pdf([
                "<< /Type /Catalog /Pages 2 0 R /Dests << /line \(horizontal) /point \(xyz) >> /Names << /Dests << /Names [<410042> << /D \(region) >>] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> >>",
                "<< /Type /Annot /Subtype /Link \(rect) /Dest \(named ? "/line" : horizontal) >>",
                "<< /Type /Annot /Subtype /Link \(rect) /A << /S /URI /URI (https://example.com/paper) >> >>",
                "<< /Type /Annot /Subtype /Text \(rect) /Contents (Margin note) >>",
                "<< /Type /Annot /Subtype /Link /Rect [30 40 60 50] /A << /S /GoTo /D \(named ? "<410042>" : region) >> >>",
                "<< /Type /Annot /Subtype /Link /Rect [50 60 80 75] /Dest \(named ? "/point" : xyz) >>",
            ]), format: .pdf)
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.binderStartsOnFront = false
        let prepared = try await DocumentRenderer().prepare(.binder([child, child]), settings: settings)

        func check(_ document: PDFDocument, stage: String) async throws {
            let backing = try #require(document.documentRef)
            let raw = try await ReadingPDFRawNavigation.capture(backing)
            for index in [0, 2] {
                let page = try #require(document.page(at: index))
                let target = try #require(document.page(at: index + 1))
                let annotations = page.annotations.filter { $0.type != "Popup" }
                try #require(annotations.count == 5)
                for i in [0, 3, 4] {
                    let link = annotations[i]
                    #expect(
                        ((link.action as? PDFActionGoTo)?.destination ?? link.destination)?.page === target,
                        "\(stage) p\(index + 1), link \(i)")
                }
                #expect(
                    annotations[0].bounds == annotations[1].bounds && annotations[1].bounds == annotations[2].bounds)
                #expect(annotations[1].url?.absoluteString == "https://example.com/paper")
                #expect(annotations[2].type == "Text" && annotations[2].contents == "Margin note")
                let destinations = raw.links.filter { $0.page == index }.compactMap { $0.action.target }
                #expect(
                    destinations == [
                        .init(page: index + 1, mode: "FitH", arguments: [nil]),
                        .init(page: index + 1, mode: "FitR", arguments: [21, 32, 104, 205]),
                        .init(page: index + 1, mode: "XYZ", arguments: [73, nil, 1.5]),
                    ], "\(stage) p\(index + 1)")
            }
        }
        try await check(prepared.viewDocument, stage: "binder")
        let reopened = try await StandalonePage.reopenBinder(prepared.viewDocument)
        try await check(reopened, stage: "reopened")
        let bytes = try await ReadingPDFExporter.data(from: prepared.viewDocument, entries: [], title: "Binder")
        try await check(#require(PDFDocument(data: bytes)), stage: "exported")
    }

    @Test("名前付き XYZ だけの合本は macOS 26 以降で開き直さず、表示と書き出しの宛先を保つ", arguments: [0.0, 1.5])
    func boundXYZInMemory(zoom: CGFloat) async throws {
        // A legacy name alongside a name tree can leave PDFKit without a destination page.
        let child = DocumentSource(
            data: pdf([
                "<< /Type /Catalog /Pages 2 0 R /Dests << /point [4 0 R /XYZ 73 null \(zoom)] >> /Names << /Dests << /Names [] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Annots [5 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> >>",
                "<< /Type /Annot /Subtype /Link /Rect [10 10 20 20] /Dest /point >>",
            ]), format: .pdf)
        var settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.binderStartsOnFront = false
        let prepared = try await DocumentRenderer().prepare(.binder([child, child]), settings: settings)
        let view = prepared.viewDocument
        if #available(macOS 26, *) {
            // Only the assembled instance carries the occurrence records; a verified reopen has its own dictionaries.
            guard case .bound = view.binderNavigation else {
                Issue.record("The XYZ binder was reopened.")
                return
            }
        }
        let bytes = try await ReadingPDFExporter.data(from: view, entries: [], title: "Binder")
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        for index in [0, 2] {
            let link = try #require(view.page(at: index)?.annotations.first)
            let target = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
            #expect(target.page === view.page(at: index + 1))
            #expect(target.point == CGPoint(x: 73, y: kPDFDestinationUnspecifiedValue))
            if zoom == 0 {
                #expect(target.zoom == kPDFDestinationUnspecifiedValue || target.zoom == 0)
            } else {
                #expect(target.zoom == zoom)
            }
            #expect(
                raw.links.first { $0.page == index }?.action.target
                    == .init(page: index + 1, mode: "XYZ", arguments: [73, nil, zoom]))
        }
    }

    @Test("しおりを検証できない合本は表示でき、表示用のリンクを基準に読むための PDF を書き出さない")
    func binderReopenWithInvalidOutline() async throws {
        let manuscript = try #require(PDFDocument(data: markedPages(rotated: false)))
        let document = PDFDocument()
        for index in 0..<manuscript.pageCount {
            let source = try #require(manuscript.page(at: index))
            document.insert(try #require(StandalonePage.copy(of: source)), at: index)
        }
        let first = try #require(document.page(at: 0))
        let target = try #require(document.page(at: 1))
        let link = try #require(first.annotations.first)
        let destination = document.destination(on: target, at: CGPoint(x: 70, y: 110))
        destination.zoom = 1
        link.action = PDFActionGoTo(destination: destination)
        #expect(target.bounds(for: .mediaBox).origin == CGPoint(x: 7, y: 29))
        try checkMarkedLink(document, from: 0)

        // A released bookmark page fails verification. A native write can drop the broken action and
        // leave a perfectly readable link whose coordinates still refer to the old page origin.
        let lost = autoreleasepool { PDFDestination(page: PDFPage(), at: .zero) }
        try #require(lost.page == nil)
        let root = PDFOutline()
        let leaf = PDFOutline()
        leaf.label = "Lost"
        root.insertChild(leaf, at: 0)
        leaf.action = PDFActionGoTo(destination: lost)
        document.outlineRoot = root
        await #expect(throws: ReadingPDFExporter.ExportError.self) {
            _ = try await ReadingPDFExporter.data(from: document)
        }
        let reopened = try await StandalonePage.reopenBinder(document)
        #expect(reopened !== document)
        #expect(reopened.pageCount == 2)
        let displayedTarget = try #require(reopened.page(at: 1))
        #expect(try markOnPaper(displayedTarget) == CGRect(x: 59, y: 78, width: 8, height: 6))

        // Both the plain exporter and the app's metadata/decorations entry point must refuse the display copy.
        for withMetadata in [false, true] {
            do {
                if withMetadata {
                    _ = try await ReadingPDFExporter.data(from: reopened, entries: [], title: "Binder")
                } else {
                    _ = try await ReadingPDFExporter.data(from: reopened)
                }
                Issue.record("Export accepted a display-only binder.")
            } catch ReadingPDFExporter.ExportError.unverifiedBinderNavigation {}
        }
    }

    @Test("表示用に退避した文書を合本に含めると、表示番号を加えた後も書き出しを断る")
    func derivedDisplayFallback() async throws {
        let source = try #require(PDFDocument(data: file(bookmark: "/Dest [null /Fit]")))
        let fallback = try await StandalonePage.reopenBinder(source)
        let renderer = DocumentRenderer(paginate: { _ in fallback })
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        let child = DocumentSource(data: Data("Child".utf8), format: .markdown)
        let prepared = try await renderer.prepare(.binder([child]), settings: settings)
        try #require(prepared.viewDocument.pageCount == 1)
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let decorated = try #require(ViewPageDocument.make(prepared.viewDocument, plan: plan, margin: 0))
        do {
            _ = try await ReadingPDFExporter.data(from: decorated, entries: [], title: "Binder")
            Issue.record("Export accepted a copy derived from a display-only binder.")
        } catch ReadingPDFExporter.ExportError.unverifiedBinderNavigation {}
    }

    @Test("座標差が 1・4 ULP なら保存値を保ち、5 ULP なら宛先を修復して書き出す", arguments: [1, 4, 5])
    func coordinateTolerance(ulps: Int) async throws {
        // Keep the saved operand exactly representable and set the live operand in memory.
        // Otherwise a PDF decimal parser can round a boundary case before the comparison even starts.
        for base: CGFloat in [96, -96, 0.0009765625] {
            let bytes = file(link: "/Dest [3 0 R /XYZ \(base) 80 1]", bookmark: "/Dest [3 0 R /Fit]")
            let document = try #require(PDFDocument(data: bytes))
            let page = try #require(document.page(at: 0))
            let annotation = try #require(page.annotations.first)
            let wanted = base + CGFloat(ulps) * base.ulp
            let destination = document.destination(on: page, at: CGPoint(x: wanted, y: 80))
            destination.zoom = 1
            annotation.action = PDFActionGoTo(destination: destination)
            let capture = try await ReadingPDFNavigation(document)
            try #require(capture.links.first?.action.target?.arguments[0] == wanted)
            let stored = try await ReadingPDFRawNavigation.read(bytes)
            try #require(stored.links.first?.action.target?.arguments[0] == base)
            let result = try await capture.verified(bytes, pageCount: 1, stage: "export")
            if ulps <= 4 {
                #expect(result == bytes)
            } else {
                #expect(result.count > bytes.count)
                let repaired = try await ReadingPDFRawNavigation.read(result)
                let x = try #require(repaired.links.first?.action.target?.arguments[0])
                #expect(x != base && abs(x - wanted) <= wanted.ulp)
            }
        }
    }

    @Test("未指定の座標とゼロの入れ替わり、および 1 ULP のズーム差を修復する")
    func exactNullAndZoom() async throws {
        for (wanted, saved) in [
            ("null 80 1", "0 80 1"), ("0 80 1", "null 80 1"), ("16 80 1", "16 80 1.0000000000000002"),
        ] {
            func input(_ operands: String) -> Data {
                file(link: "/Dest [3 0 R /XYZ " + operands + "]", bookmark: "/Dest [3 0 R /Fit]")
            }
            let original = input(wanted)
            let candidate = input(saved)
            let capture = try await ReadingPDFNavigation(#require(PDFDocument(data: original)))
            let before = try await ReadingPDFRawNavigation.read(candidate)
            let expected = try await ReadingPDFRawNavigation.read(original)
            try #require(before.links != expected.links)
            let result = try await capture.verified(candidate, pageCount: 1, stage: "export")
            #expect(result.count > candidate.count)
            let repaired = try await ReadingPDFRawNavigation.read(result)
            #expect(repaired.links == expected.links)
        }
    }

    @Test("原点が変わる保存と変わらない保存のどちらでも、各表示方法の座標だけを移す")
    func destinationOperands() async throws {
        // Supply both layouts explicitly so coverage does not depend on the host PDFKit's choice of origin.
        for (before, after) in [
            ("XYZ null 80 1.5", "XYZ null 67 1.5"), ("XYZ 40 null 1.5", "XYZ 33 null 1.5"),
            ("FitH 80", "FitH 67"), ("FitBH 80", "FitBH 67"), ("FitV 40", "FitV 33"), ("FitBV 40", "FitBV 33"),
            ("FitH null", "FitH null"), ("FitR 17 23 107 203", "FitR 10 10 100 190"), ("Fit", "Fit"), ("FitB", "FitB"),
        ] {
            func link(_ operands: String) -> String { "/Dest [3 0 R /" + operands + "]" }
            let original = file(link: link(before), mediaBox: "7 13 207 313", rect: "17 23 27 33")
            let captured = try await ReadingPDFNavigation(#require(PDFDocument(data: original)))
            let unchanged = try await captured.verified(original, pageCount: 1, stage: "original")
            let shifted = file(link: link(before))
            let repaired = try await captured.verified(shifted, pageCount: 1, stage: "shifted")
            let expected = try await ReadingPDFRawNavigation.read(file(link: link(after)))
            let raw = try await ReadingPDFRawNavigation.read(repaired)
            #expect(raw.links[0].action == expected.links[0].action, "\(before)")
            let reread = try await ReadingPDFRawNavigation.read(unchanged)
            let input = try await ReadingPDFRawNavigation.read(original)
            #expect(reread.links[0].action == input.links[0].action, "\(before)")
        }
    }

    @Test("保存後に内部リンクの領域が移動するか注釈自体が消えたら書き出しを断る", arguments: [true, false])
    func damagedLinkIdentity(removed: Bool) async throws {
        let rect = "17 23 27 33"
        let source = try #require(PDFDocument(data: file(mediaBox: "7 13 207 313", rect: rect)))
        let expected = try await ReadingPDFNavigation(source)
        // Keeping the original absolute rectangle moves the link on the rebased page.
        let saved = file(rect: removed ? nil : rect)
        do {
            _ = try await expected.verified(saved, pageCount: 1, stage: "export")
            Issue.record("壊れた内部リンクが保存された")
        } catch ReadingPDFExporter.ExportError.navigation(let detail) {
            #expect(detail.contains(removed ? "missing link annotation" : "link identity differs"))
        }
    }

    @Test("XYZ の倍率が欠けた引用リンクは、表示中の座標が読めても生の宛先を示して断る")
    func missingCitationZoom() async throws {
        let bytes = pdf([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /Annots [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R >>", "<< /Type /Page /Parent 2 0 R >>",
            "<< /Type /Annot /Subtype /Link /Rect [120 300 180 312] /Dest 7 0 R >>",
            "[5 0 R /XYZ 108 656.1506]",
        ])
        let view = try #require(PDFDocument(data: bytes))
        do {
            _ = try await ReadingPDFExporter.data(from: view, entries: [], title: "Paper")
            Issue.record("倍率を省略した XYZ が受理された")
        } catch ReadingPDFExporter.ExportError.navigation(let detail) {
            #expect(detail.contains("view p1 annotation=0"))
            #expect(detail.contains("/Dest [p3 /XYZ 108 656.1506] (4 elements)"), "\(detail)")
        }
    }

    // Match the two ordered blocks in the captured NeurIPS page, including PDFKit's escaped page markers.
    private func citationPage(withCopies: Bool, changedCopy: Bool = false) -> Data {
        let targets = [
            (3, 656.1506), (3, 656.1506), (1, 229.7176), (2, 309.0377), (2, 149.261),
            (3, 701.9779), (3, 701.9779), (3, 638.2182), (3, 638.2182), (1, 94.79188),
        ]
        var copies: [String] = []
        var originals: [String] = []
        for (i, target) in targets.enumerated() {
            let rect = "/Subtype /Link /Rect [120 \(30 + 20 * i) 180 \(42 + 20 * i)]"
            func action(_ page: Int) -> String { "/A << /S /GoTo /D [/#2323\(page) /XYZ 108 \(target.1)] >>" }
            let attributes = "/H /I /F 4 /BS << /W 0 >> /M (D:20261127)"
            copies.append("<< \(rect) \(attributes) \(action(changedCopy && i == 8 ? 1 : target.0)) >>")
            let dest = "/Dest [\(target.0 + 2) 0 R /XYZ 108 \(target.1) null]"
            originals.append("<< \(rect) /Border [0 0 0] \(withCopies ? action(target.0) : "") \(dest) >>")
        }
        let annotations = (withCopies ? copies : []) + originals
        let slots = annotations.indices.map { "\($0 + 6) 0 R" }.joined(separator: " ")
        return pdf(
            [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << >> >>",
                "<< /Type /Page /Parent 2 0 R /Annots [\(slots)] >>",
                "<< /Type /Page /Parent 2 0 R >>", "<< /Type /Page /Parent 2 0 R >>",
            ] + annotations)
    }

    private func checkCitations(
        from view: PDFDocument, against expected: [ReadingPDFRawNavigation.Link], footer: Bool = false
    ) async throws {
        var options = PrintOptions()
        options.furniture = .name
        let placement = try #require(
            PDFComposer.furniture(
                onPage: 0, at: 0, pageCount: 3, layout: .letterSingle, options: options,
                context: .init(fileName: "NeurIPS")))
        let bytes = try await ReadingPDFExporter.data(
            from: view, entries: [], title: "NeurIPS", furniture: footer ? [0: placement] : [:])
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        let saved = try #require(PDFDocument(data: bytes))
        try #require(saved.pageCount == 3)
        let annotations = try #require(saved.page(at: 0)?.annotations)
        try #require(annotations.count == 10)
        try #require(raw.links.filter { $0.page == 0 }.count == annotations.count)
        for (i, link) in expected.enumerated() {
            let target = try #require(link.action.target)
            #expect(raw.links[i].annotation == i && raw.links[i].action.target == target)
            let annotation = annotations[i]
            #expect(ReadingPDFNavigation.sameBounds(annotation.bounds, link.bounds))
            let dest = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
            #expect(dest.page === saved.page(at: target.page))
            #expect(abs(dest.point.x - (try #require(target.arguments[0]))) < 0.001)
            #expect(abs(dest.point.y - (try #require(target.arguments[1]))) < 0.001)
            #expect(dest.zoom == kPDFDestinationUnspecifiedValue)
        }
    }

    @Test("表示用コピーを作っても元ページの注釈辞書は増えず、読む PDF の引用十件が同じ場所に着く")
    func viewCopyPreservesCitations() async throws {
        let bytes = citationPage(withCopies: false)
        let expected = try await ReadingPDFRawNavigation.read(bytes)
        let source = try #require(PDFDocument(data: bytes))
        let plan = ViewPageLayout(
            pageCount: 3,
            options: .init(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        try #require(copy.page(at: 0)?.annotations.count == 10)
        try #require(source.page(at: 0)?.annotations.count == 10)
        let backing = try await ReadingPDFRawNavigation.capture(try #require(source.documentRef))
        #expect(backing.links.count == 10)
        try await checkCitations(from: source, against: expected.links)
    }

    @Test("保存済みの PDFKit の二重の注釈配列から十件の引用を元の順番と行先で書き出す", arguments: [false, true])
    func exportedDuplicateCitations(footer: Bool) async throws {
        let bytes = citationPage(withCopies: true)
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        let view = try #require(PDFDocument(data: bytes))
        #expect(raw.pdfKitCopyCounts == [0: 10])
        try #require(raw.links.count == 20 && view.page(at: 0)?.annotations.count == 20)
        try await checkCitations(from: view, against: Array(raw.links.suffix(10)), footer: footer)
    }

    @Test("同じ位置でも複製と元の行先が一件でも異なれば、欠落した飛び先を推定しない")
    func mismatchedDuplicateCitation() async throws {
        let view = try #require(PDFDocument(data: citationPage(withCopies: true, changedCopy: true)))
        await #expect(throws: ReadingPDFExporter.ExportError.self) {
            _ = try await ReadingPDFExporter.data(from: view, entries: [], title: "NeurIPS")
        }
    }

    // Reproduce the earlier window copy without WebKit. Native page copies share the source /Annots array.
    private func copyAndRebind(_ source: PDFDocument, hasContents: Bool = false) throws -> PDFDocument {
        let annotations = try #require(source.page(at: 0)).annotations
        let view = PDFDocument()
        for i in 0..<source.pageCount {
            let original = try #require(source.page(at: i))
            view.insert(try #require(original.copy() as? PDFPage), at: i)
        }
        let page = try #require(view.page(at: 0))
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        for (i, annotation) in annotations.enumerated() {
            let dest = try #require((annotation.action as? PDFActionGoTo)?.destination)
            let index = source.index(for: try #require(dest.page))
            let target = try #require(view.page(at: index))
            let copy = try #require(annotation.copy() as? PDFAnnotation)
            if hasContents && i == 8 { copy.contents = "A distinct annotation" }
            page.addAnnotation(copy)
            copy.action = PDFActionGoTo(destination: view.destination(on: target, at: dest.point))
        }
        return view
    }

    @Test("表示中の十件と元辞書の二十件を照合し、独自の内容を持つ注釈があれば件数を示して断る", arguments: [false, true])
    func liveDuplicateCitations(hasContents: Bool) async throws {
        let bytes = citationPage(withCopies: false)
        let expected = try await ReadingPDFRawNavigation.read(bytes)
        let source = try #require(PDFDocument(data: bytes))
        let first = try #require(source.page(at: 0))
        let copy = try copyAndRebind(source, hasContents: hasContents)
        defer { withExtendedLifetime((copy, first)) {} }
        try #require(source.page(at: 0)?.annotations.count == 10)
        let backing = try await ReadingPDFRawNavigation.capture(try #require(source.documentRef))
        try #require(backing.annotationCounts == [20, 0, 0])
        if hasContents {
            do {
                _ = try await ReadingPDFExporter.data(from: source, entries: [], title: "NeurIPS")
                Issue.record("独自の内容を持つ注釈を複製とみなして消した")
            } catch ReadingPDFExporter.ExportError.navigation(let detail) {
                #expect(detail.contains("missing original link"), "\(detail)")
                #expect(detail.contains("PDFKit annotations=10, original /Annots=20"), "\(detail)")
            }
        } else {
            try await checkCitations(from: source, against: expected.links)
        }
    }

    // PDF name escaping turns the file token /#23233 into the Core Graphics name "#233".
    private func pdfKitCitation() -> Data {
        pdf([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /Annots [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R >>", "<< /Type /Page /Parent 2 0 R >>",
            "<< /Subtype /Link /Rect [120 300 180 312] /A << /S /GoTo /D [/#23233 /XYZ 108.00000000000003 656.1505859375] >> >>",
        ])
    }

    @Test("PDFKit が表示中の引用に合成した短い宛先を、読む PDF ではページ参照と null に直す")
    func canonicalizesLiveCitation() async throws {
        let bytes = pdfKitCitation()
        let point = CGPoint(x: 108.00000000000003, y: 656.1505859375)
        let raw = try await ReadingPDFRawNavigation.read(bytes)
        let marker = ReadingPDFRawNavigation.Action.pdfKitXYZ(pageNumber: 3, point: point)
        try #require(raw.links.map(\.action) == [marker])

        // Install a native action on the page tree, just as the paper compositors do.
        let view = try await PDFDrawing.document(pageSize: CGSize(width: 612, height: 792)) { context in
            for _ in 0..<3 {
                context.beginPDFPage(nil)
                context.endPDFPage()
            }
        }
        let page = try #require(view.page(at: 2))
        let source = try #require(view.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 120, y: 300, width: 60, height: 12), forType: .link, withProperties: nil)
        annotation.action = PDFActionGoTo(destination: view.destination(on: page, at: point))
        source.addAnnotation(annotation)
        let target = ReadingPDFNavigationWriter.Destination(page: 2, mode: "XYZ", arguments: [point.x, point.y, nil])
        let exported = try await ReadingPDFExporter.data(from: view, entries: [], title: "Paper")
        // A reader that follows the abbreviated bytes still cannot make their dictionary valid.
        let expected = try await ReadingPDFNavigation(view)
        let repaired = try await expected.verified(bytes, pageCount: 3, stage: "export") { data in
            PDFDocument(data: data == bytes ? exported : data)
        }
        for data in [repaired, exported] {
            let raw = try await ReadingPDFRawNavigation.read(data)
            #expect(raw.links.map(\.action) == [.internalDestination(target)])
            let reopened = try #require(PDFDocument(data: data))
            let link = try #require(reopened.page(at: 0)?.annotations.first)
            let dest = try #require((link.action as? PDFActionGoTo)?.destination ?? link.destination)
            #expect(dest.page === reopened.page(at: 2))
            #expect(abs(dest.point.x - point.x) < 0.001 && abs(dest.point.y - point.y) < 0.001)
            #expect(dest.zoom == kPDFDestinationUnspecifiedValue)
        }
    }

    @Test("PDFKit の短い宛先は、表示のページ・座標・倍率が食い違うか行先を失っていれば断る")
    func rejectsUnconfirmedCitation() async throws {
        let raw = try await ReadingPDFRawNavigation.read(pdfKitCitation())
        let original = try #require(raw.links.first?.action)
        let y = CGFloat(656.1505859375)
        // Compare the two observations independently: mutating a live annotation can regenerate its pageRef.
        let live: [ReadingPDFRawNavigation.Action] = [
            .releasedPage, .none, .other,
            .internalDestination(.init(page: 1, mode: "XYZ", arguments: [108, y, nil])),
            .internalDestination(.init(page: 2, mode: "XYZ", arguments: [109, y, nil])),
            .internalDestination(.init(page: 2, mode: "XYZ", arguments: [108, y + 0.0001, nil])),
            .internalDestination(.init(page: 2, mode: "XYZ", arguments: [108, y, 2])),
        ]
        for action in live {
            #expect(throws: ReadingPDFExporter.ExportError.self) {
                _ = try ReadingPDFNavigation.resolve(action, original: original, detail: "view p1 annotation=0")
            }
        }
    }

    @Test("引用の前後に外部リンクがあっても、読む PDF を開き直すと文献のページ・座標・倍率が保たれる")
    func writtenCitationDestination() async throws {
        let external = try #require(URL(string: "https://example.com/paper"))
        let pageSize = CGSize(width: 612, height: 792)
        let bytes = try await PDFDrawing.data(pageSize: pageSize) { context in
            context.beginPDFPage(nil)
            context.setURL(external as CFURL, for: CGRect(x: 100, y: 480, width: 60, height: 12))
            context.setURL(external as CFURL, for: CGRect(x: 100, y: 320, width: 60, height: 12))
            context.endPDFPage()
            for _ in 0..<2 {
                context.beginPDFPage(nil)
                context.endPDFPage()
            }
        }
        let rect = CGRect(x: 100, y: 400, width: 60, height: 12)
        let destination = ReadingPDFNavigationWriter.Destination(page: 2, mode: "XYZ", arguments: [108, 656.1506, nil])
        let linked = try await ReadingPDFNavigationWriter.adding(
            [.init(page: 0, bounds: rect, destination: destination, beforeAnnotation: 1)], to: bytes)
        let source = try #require(PDFDocument(data: linked))
        let saved = try await ReadingPDFExporter.data(from: source, entries: [], title: "Paper")
        let raw = try await ReadingPDFRawNavigation.read(saved)
        #expect(raw.links.map(\.action) == [.other, .internalDestination(destination), .other])
        let reopened = try #require(PDFDocument(data: saved))
        let annotations = try #require(reopened.page(at: 0)?.annotations)
        try #require(annotations.count == 3)
        #expect(annotations[0].url == external && annotations[2].url == external)
        #expect(annotations[1].bounds == rect)
        let target = try #require((annotations[1].action as? PDFActionGoTo)?.destination ?? annotations[1].destination)
        #expect(target.page === reopened.page(at: 2))
        #expect(abs(target.point.x - 108) < 0.001 && abs(target.point.y - 656.1506) < 0.001)
        #expect(target.zoom == kPDFDestinationUnspecifiedValue)
    }

    @Test("解決できない内部リンクやしおりがあれば、宛先を持たない親項目として保存しない")
    func unresolvedTargets() async throws {
        for damaged in [
            file(link: "/A << /S /GoTo /D (missing) >>"),
            file(bookmark: "/Dest [null /Fit]"),
            file(bookmark: "/A << /S /GoTo >>"),
            file(link: "/Dest [3 0 R /Unknown 2]"),
            file(link: "/Dest << /D [3 0 R /Fit] >>"),
            file(link: "/A << /S /GoTo /D [3 0 R /XYZ 0 100] >>"),
        ] {
            let document = try #require(PDFDocument(data: damaged))
            await #expect(throws: ReadingPDFExporter.ExportError.self) {
                _ = try await ReadingPDFExporter.data(from: document)
            }
        }
    }

    @Test("しおりやリンクの表示方法と引数を直し、nullと矩形座標を原文のまま保つ")
    func exactDestinations() async throws {
        let original = file()
        let expected = try #require(PDFDocument(data: original))
        let snapshot = try await ReadingPDFNavigation(expected)
        let readable = file(link: "/Dest [3 0 R /FitH null]", bookmark: "/Dest [3 0 R /FitR 21 32 104 205]")
        let clean = try await snapshot.verified(readable, pageCount: 1, stage: "clean")
        #expect(clean == readable)
        let damaged = file(
            link: "/Dest [3 0 R /FitV null]", bookmark: "/Dest [3 0 R /FitR 22 32 104 205]")
        let fixed = try await snapshot.verified(damaged, pageCount: 1, stage: "damaged")
        #expect(fixed.count > damaged.count)
        let provider = try #require(CGDataProvider(data: fixed as CFData))
        let document = try #require(CGPDFDocument(provider))
        defer { withExtendedLifetime(document) {} }
        let page = try #require(document.page(at: 1)?.dictionary)
        var annotations: CGPDFArrayRef?
        try #require(CGPDFDictionaryGetArray(page, "Annots", &annotations))
        var link: CGPDFDictionaryRef?
        try #require(CGPDFArrayGetDictionary(annotations!, 0, &link))
        var destination: CGPDFArrayRef?
        try #require(CGPDFDictionaryGetArray(link!, "Dest", &destination))
        var mode: UnsafePointer<CChar>?
        try #require(CGPDFArrayGetName(destination!, 1, &mode))
        #expect(String(cString: mode!) == "FitH")
        var argument: CGPDFObjectRef?
        try #require(CGPDFArrayGetObject(destination!, 2, &argument))
        #expect(CGPDFObjectGetType(argument!) == .null)

        var node = try #require(document.catalog)
        for key in ["Outlines", "First", "First", "First"] { node = try dictionary(node, key) }
        try #require(CGPDFDictionaryGetArray(node, "Dest", &destination))
        try #require(CGPDFArrayGetName(destination!, 1, &mode))
        #expect(String(cString: mode!) == "FitR")
        let arguments = try (2..<6).map { index in
            var n: CGPDFReal = 0
            try #require(CGPDFArrayGetNumber(destination!, index, &n))
            return n
        }
        #expect(arguments == [21, 32, 104, 205])
    }

    @Test("辞書の表示指定が一致していても、読み手が追えなくなったリンクとしおりを修復する", arguments: [false, true])
    func readerReadback(namedSource: Bool) async throws {
        let explicit = "/Dest [3 0 R /FitH null]"
        // The legacy name has the same FitH and null as the explicit destination. Quartz
        // resolves it even on systems where PDFKit reports a destination without a page.
        let named = file(link: "/Dest /left", bookmark: "/Dest /left")
        let view = try #require(PDFDocument(data: namedSource ? named : file(link: explicit, bookmark: explicit)))
        let expected = try await ReadingPDFNavigation(view)
        func pages(in document: PDFDocument) -> [Int?] {
            let annotation = document.page(at: 0)?.annotations.first
            let leaf = document.outlineRoot?.child(at: 0)?.child(at: 0)?.child(at: 0)
            return [
                (annotation?.action as? PDFActionGoTo)?.destination ?? annotation?.destination,
                leaf?.destination ?? (leaf?.action as? PDFActionGoTo)?.destination,
            ].map { dest in dest?.page.map { document.index(for: $0) } }
        }
        if !namedSource { try #require(pages(in: view) == [0, 0], "view: link, bookmark") }
        let target = ReadingPDFNavigationWriter.Destination(page: 0, mode: "FitH", arguments: [nil])
        #expect(expected.links.first?.action.target == target, "view: link")
        #expect(expected.outline.first { $0.title == "Leaf" }?.action.target == target, "view: bookmark")
        let saved = try #require(PDFDocument(data: named))
        let before = pages(in: saved)
        let bytes = try await expected.verified(named, pageCount: 1, stage: "saved")
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(
            pages(in: reopened) == [0, 0], "view=\(pages(in: view)) saved=\(before) repaired=\(pages(in: reopened))")
        if before == [0, 0] {
            #expect(bytes == named)
        } else {
            let raw = try await ReadingPDFRawNavigation.read(bytes)
            if before[0] == nil { #expect(raw.links.first?.action == .internalDestination(target), "repaired: link") }
            if before[1] == nil {
                #expect(
                    raw.outline.first { $0.title == "Leaf" }?.action == .internalDestination(target),
                    "repaired: bookmark")
            }
        }
    }

    @Test("明示的な宛先に修復しても読み手がページを返さなければ書き出しを断る", arguments: [false, true])
    func unreadableAfterRepair(bookmark: Bool) async throws {
        let named = file(link: "/Dest /left", bookmark: "/Dest /left")
        let view = try #require(PDFDocument(data: named))
        let expected = try await ReadingPDFNavigation(view)
        let explicit = "/Dest [3 0 R /FitH null]"
        // Model a reader that loses just one destination on both opens. Quartz still reads
        // the actual saved and incrementally repaired bytes, including their destination operands.
        let unreadable = file(link: bookmark ? explicit : "", bookmark: bookmark ? "" : explicit)
        let item = bookmark ? "bookmark=3" : "p1 annotation=0"
        do {
            _ = try await expected.verified(named, pageCount: 1, stage: "export") { _ in
                PDFDocument(data: unreadable)
            }
            Issue.record("repaired \(item): accepted a destination without a readable page")
        } catch ReadingPDFExporter.ExportError.navigation(let detail) {
            #expect(detail.contains("saved \(item)"), "\(detail)")
            #expect(detail.contains("repaired \(item)"), "\(detail)")
        }
    }

    @Test("元の XYZ 辞書でページだけが欠けても、表示中の有効な行先を保存する")
    func liveDestinationWithMissingBackingPage() async throws {
        let source = try #require(PDFDocument(data: file(link: "/Dest [null /XYZ 20 40 null]")))
        let page = try #require(source.page(at: 0))
        let link = try #require(page.annotations.first)
        link.action = PDFActionGoTo(destination: source.destination(on: page, at: CGPoint(x: 35, y: 82)))
        let bytes = try await ReadingPDFExporter.data(from: source)
        let saved = try #require(PDFDocument(data: bytes))
        let annotation = try #require(saved.page(at: 0)?.annotations.first)
        let target = try #require((annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
        #expect(
            target.page === saved.page(at: 0) && target.point == CGPoint(x: 35, y: 82),
            "saved: expected p1@(35,82), got \(target)")
    }

    @Test("元の PDF にあるリンクを表示中に移したら、新しい座標を保存する")
    func editedLink() async throws {
        let original = file(link: "/Dest [3 0 R /XYZ 20 40 null]")
        let document = try #require(PDFDocument(data: original))
        let page = try #require(document.page(at: 0))
        let annotation = try #require(page.annotations.first)
        let point = CGPoint(x: 58.51234567, y: 99.955640125)
        annotation.action = PDFActionGoTo(destination: document.destination(on: page, at: point))
        let exported = try await ReadingPDFExporter.data(
            from: document, entries: [], title: "Test", preservesOutline: true)
        let raw = try await ReadingPDFRawNavigation.read(exported)
        guard case .internalDestination(let destination) = raw.links.first?.action else {
            Issue.record("内部リンクの宛先がない")
            return
        }
        #expect(destination.mode == "XYZ")
        #expect(abs(try #require(destination.arguments[0]) - point.x) < 0.0001)
        #expect(abs(try #require(destination.arguments[1]) - point.y) < 0.0001)
    }

    private func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var child: CGPDFDictionaryRef?
        try #require(CGPDFDictionaryGetDictionary(parent, key, &child))
        return try #require(child)
    }

    @Test("閉じた枝を復元して、ルートと枝の件数に見えている子孫だけを数える")
    func collapsedBranches() async throws {
        let expected = try #require(PDFDocument(data: file()))
        let open = file(open: true)
        let fixed = try await ReadingPDFNavigation(expected).verified(
            open, pageCount: 1, stage: "opened"
        )
        let provider = try #require(CGDataProvider(data: fixed as CFData))
        let document = try #require(CGPDFDocument(provider))
        defer { withExtendedLifetime(document) {} }
        var node = try #require(document.catalog)
        for (key, count) in [("Outlines", 1), ("First", -3), ("First", 1)] {
            node = try dictionary(node, key)
            var stored = 0
            try #require(CGPDFDictionaryGetInteger(node, "Count", &stored))
            #expect(stored == count)
        }
    }
}
