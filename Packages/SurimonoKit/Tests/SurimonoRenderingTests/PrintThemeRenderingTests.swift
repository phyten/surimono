import AppKit
import OSLog
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PrintThemeRenderingTests {
    private func render(_ text: String, theme id: String, format: DocumentFormat = .markdown) async throws
        -> PDFDocument
    {
        try await render(text, theme: try #require(PrintThemeLibrary.load().first { $0.id == id }), format: format)
    }

    private func render(_ text: String, theme: PrintTheme, format: DocumentFormat = .markdown) async throws
        -> PDFDocument
    {
        _ = NSApplication.shared
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(text.utf8), format: format), settings: settings)
        return result.logicalDocument
    }

    /// The page drawn on white at twice its size, as RGB rows from the top.
    private func pixels(of page: PDFPage) throws -> (width: Int, height: Int, data: [UInt8]) {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * 2)
        let height = Int(bounds.height * 2)
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = try data.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        #expect(drawn)
        return (width, height, data)
    }

    @Test("囲みの札と地とアイコンは印刷でも色のまま出る", .timeLimit(.minutes(1)))
    func calloutPrintsItsTagGroundAndIcon() async throws {
        let text = ":::warning 表題\n本文\n:::"
        let image = try pixels(of: try #require(try await render(text, theme: "standard").page(at: 0)))
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        // The same page with only the icon gone: hidden keeps the layout, so the two differ by the icon alone.
        let hidden = standard.css + "\n.callout-icon { visibility: hidden; }"
        let plain = PrintTheme(id: "plain", name: "Plain", css: hidden)
        let control = try pixels(of: try #require(try await render(text, theme: plain).page(at: 0)))
        func isClose(_ data: [UInt8], _ index: Int, _ color: [Int]) -> Bool {
            (0..<3).allSatisfy { abs(Int(data[index + $0]) - color[$0]) <= 3 }
        }
        let tag = [0x79, 0x50, 0x0d]
        var tagPixels = 0
        var groundPixels = 0
        var iconPixels = 0
        for index in stride(from: 0, to: image.data.count, by: 4) {
            if isClose(image.data, index, tag) { tagPixels += 1 }
            // --callout-warning at 8% on white paper.
            if isClose(image.data, index, [0xf4, 0xf0, 0xeb]) { groundPixels += 1 }
            // The icon's ink in the tag's ink, on what is otherwise the tag's fill.
            if isClose(image.data, index, [255, 255, 255]), isClose(control.data, index, tag) { iconPixels += 1 }
        }
        #expect(tagPixels > 1000)
        #expect(groundPixels > 10000)
        #expect(iconPixels > 20)
    }

    @Test("文書の先頭の囲みの札はページの余白の中で切れない", .timeLimit(.minutes(1)))
    func leadingCalloutKeepsItsTag() async throws {
        let page = try #require(try await render(":::note 表題\n本文\n:::", theme: "standard").page(at: 0))
        let index = ((page.string ?? "") as NSString).range(of: "表題").location
        try #require(index != NSNotFound)
        let gap = page.bounds(for: .mediaBox).maxY - page.characterBounds(at: index).maxY
        #expect(gap >= 15 * 72 / 25.4 - 1)
    }

    @Test("先頭の見出しは、見出しの上余白を足さずにページの余白のすぐ下から始まる", .timeLimit(.minutes(1)))
    func leadingHeadingStartsAtThePageMargin() async throws {
        let document = try await render("# 見出し\n\n本文", theme: "standard")
        let page = try #require(document.page(at: 0))
        #expect(page.string?.hasPrefix("見出し") == true)
        let glyph = page.characterBounds(at: 0)
        #expect(glyph.height > 0)
        let gap = page.bounds(for: .mediaBox).maxY - glyph.maxY
        let margin = 15 * 72 / 25.4
        // Glyph bounds sit a little inside the line box, so allow a point either way. The heading's own top margin
        // (about 23 pt in this theme) would push it well past the upper limit.
        #expect(gap >= margin - 1)
        #expect(gap < margin + 12)
    }

    @Test("Org の表題と引用で始まる文書も、ページの余白のすぐ下から始まる", .timeLimit(.minutes(1)))
    func leadingTitleAndQuoteStartAtThePageMargin() async throws {
        let margin = 15 * 72 / 25.4
        let cases = [("#+TITLE: 表題\n\n本文", DocumentFormat.org, "表題"), ("> 引用\n\n本文", .markdown, "引用")]
        for (text, format, first) in cases {
            let page = try #require(try await render(text, theme: "standard", format: format).page(at: 0))
            // PDF text order need not follow the page, so measure the leading block's own characters.
            let index = ((page.string ?? "") as NSString).range(of: first).location
            try #require(index != NSNotFound)
            let gap = page.bounds(for: .mediaBox).maxY - page.characterBounds(at: index).maxY
            #expect(gap < margin + 12, "\(format): \(gap)")
        }
    }

    @Test("見出しで改ページのテーマでは、見出しのすぐ後の章の見出しも新しいページの上端から始まる", .timeLimit(.minutes(1)))
    func handoutHeadingAfterHeadingStartsFlush() async throws {
        let document = try await render("# 表題\n\n## 節\n\n本文", theme: "handout")
        #expect(document.pageCount == 2)
        let page = try #require(document.page(at: 1))
        #expect(page.string?.hasPrefix("節") == true)
        let gap = page.bounds(for: .mediaBox).maxY - page.characterBounds(at: 0).maxY
        let margin = 15 * 72 / 25.4
        #expect(gap < margin + 12)
    }

    @Test("150%の文字は100%より高くページ数が増え、用紙寸法は変わらない", .timeLimit(.minutes(1)))
    func textScalePagination() async throws {
        _ = NSApplication.shared
        let markdown = (1...80).map { _ in
            "Readable text remains on the same paper. " + String(repeating: "Words fill this paragraph. ", count: 8)
        }.joined(separator: "\n\n")
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let renderer = DocumentRenderer()
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        let normal = try await renderer.render(source, settings: settings)
        settings.textScale = 1.5
        let large = try await renderer.render(source, settings: settings)
        let normalPage = try #require(normal.logicalDocument.page(at: 0))
        let largePage = try #require(large.logicalDocument.page(at: 0))
        let normalHeight = normalPage.characterBounds(at: 0).height
        let largeHeight = largePage.characterBounds(at: 0).height
        #expect(normalHeight > 0)
        #expect(largeHeight > normalHeight * 1.4)
        #expect(largeHeight < normalHeight * 1.6)
        #expect(large.logicalDocument.pageCount > normal.logicalDocument.pageCount)
        for index in 0..<large.logicalDocument.pageCount {
            let page = try #require(large.logicalDocument.page(at: index))
            #expect(page.bounds(for: .mediaBox) == normalPage.bounds(for: .mediaBox))
        }
        #expect(large.sheetDocument.pageCount == large.logicalDocument.pageCount)
        let sheetPage = try #require(large.sheetDocument.page(at: 0))
        #expect(abs(sheetPage.characterBounds(at: 0).height - largeHeight) < 0.1)
        // Synthetic fixture metrics make the real WebKit result available in the test log.
        let metrics =
            "Text scale: pages \(normal.logicalDocument.pageCount) -> \(large.logicalDocument.pageCount), "
            + "character height \(normalHeight) -> \(largeHeight), paper \(largePage.bounds(for: .mediaBox))"
        Logger(subsystem: "io.github.phyten.Surimono", category: "TextScaleTests").notice(
            "\(metrics, privacy: .public)")
    }

    @Test("見出しで改ページのテーマは、大見出し・中見出し・水平線ごとに新しいページから始める", .timeLimit(.minutes(1)))
    func handoutStartsEachSectionOnANewPage() async throws {
        let markdown =
            "# 表題\n\n前書き\n\n## 第一の話\n\n短い本文\n\n## 第二の話\n\n短い本文\n\n---\n\n水平線の後\n\n# 第二部\n\n後書き\n"
        let handout = try await render(markdown, theme: "handout")
        #expect(handout.pageCount == 5)
        let texts = (0..<handout.pageCount).map { handout.page(at: $0)?.string ?? "" }
        #expect(texts.count == 5)
        if texts.count == 5 {
            #expect(texts[0].contains("表題") && texts[0].contains("前書き"))
            #expect(texts[1].contains("第一の話"))
            #expect(texts[2].contains("第二の話"))
            #expect(texts[3].contains("水平線の後"))
            #expect(texts[4].contains("第二部") && texts[4].contains("後書き"))
        }
        #expect(try await render(markdown, theme: "standard").pageCount == 1)
    }

    @Test("書き込み用のテーマは、各ページの右に書き込める余白を空ける", .timeLimit(.minutes(1)))
    func notesLeaveRoomOnTheRight() async throws {
        let paragraph = "星見図書室の作業メモです。棚の番号と本の題名を確かめながら、刷る前の見本を作ります。"
        let markdown = (1...30).map { _ in String(repeating: paragraph, count: 3) }.joined(separator: "\n\n")
        let notes = try await render(markdown, theme: "notes")
        let standard = try await render(markdown, theme: "standard")
        func rightmostText(_ document: PDFDocument, page index: Int) throws -> CGFloat {
            let page = try #require(document.page(at: index))
            let bounds = (0..<(page.string ?? "").utf16.count).map { page.characterBounds(at: $0) }
            return (bounds.filter { $0.width > 0 }.map(\.maxX).max() ?? 0) / page.bounds(for: .cropBox).width
        }
        // The standard theme fills the line to the margin; notes stop well before it on every page.
        #expect(try rightmostText(standard, page: 0) > 0.85)
        #expect(notes.pageCount > standard.pageCount)
        for index in 0..<notes.pageCount {
            let text = notes.page(at: index)?.string ?? ""
            #expect(!text.isEmpty, "page \(index + 1)")
            #expect(try rightmostText(notes, page: index) < 0.75, "page \(index + 1)")
        }
    }
}
