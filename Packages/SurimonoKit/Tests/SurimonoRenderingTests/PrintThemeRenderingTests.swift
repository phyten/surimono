import AppKit
import OSLog
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct PrintThemeRenderingTests {
    private func render(_ markdown: String, theme id: String) async throws -> PDFDocument {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == id })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings)
        return result.logicalDocument
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
