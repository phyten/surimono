import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ThemeSamplerTests {
    private func theme(_ id: String, css: String, script: String? = nil) -> PrintTheme {
        PrintTheme(id: id, name: id, css: css, isBuiltIn: true, category: "everyday", script: script)
    }

    private func sampler(_ markdown: String, theme: PrintTheme) throws -> ThemeSampler {
        _ = NSApplication.shared
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        return try #require(
            try DocumentRenderer.themeSampler(
                for: DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings))
    }

    @Test("見本は文書の 1 ページ目を、余白を含む論理ページの大きさに描く", .timeLimit(.minutes(1)))
    func samplesTheFirstPage() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler("# 星見図書室の案内\n\n本を借りる前に確かめてください。", theme: standard)
        defer { sampler.close() }
        let page = try await sampler.firstPage(for: standard)
        #expect(page.string?.contains("星見図書室の案内") == true)
        let bounds = page.bounds(for: .mediaBox)
        // A4 is 595 × 842 pt; the default 15 mm margins leave about 510 × 757 pt for the text.
        #expect(abs(bounds.width - 595.3) < 1)
        #expect(abs(bounds.height - 841.9) < 1)
        #expect(abs(sampler.printableSize.width - 510.4) < 1)
    }

    @Test("紙のあるテーマの見本は、余白まで紙を敷く", .timeLimit(.minutes(1)))
    func samplesTheWholePaper() async throws {
        let previous = WebPaginator.clearBackground
        WebPaginator.clearBackground = { $0.setValue(false, forKey: "drawsBackground") }
        defer { WebPaginator.clearBackground = previous }
        let washi = try #require(PrintThemeLibrary.load().first { $0.id == "washi" })
        let sampler = try sampler("# 星見図書室の案内", theme: washi)
        defer { sampler.close() }
        let pixels = try PagePixels(try await sampler.firstPage(for: washi))
        for (x, y) in [(8.0, 8.0), (300.0, 600.0)] {
            let color = pixels.color(atX: x, y: y)
            #expect(abs(color.red - 0xfc) <= 3 && abs(color.green - 0xfa) <= 3 && abs(color.blue - 0xf5) <= 3)
        }
    }

    @Test("テーマを替えると見本の見た目が変わり、描いたテーマはもう一度描かない", .timeLimit(.minutes(1)))
    func switchesThemesAndKeepsSamples() async throws {
        let small = theme("small", css: "body { font-size: 10pt; }")
        let large = theme("large", css: "body { font-size: 30pt; }")
        let sampler = try sampler("文字の大きさ", theme: small)
        defer { sampler.close() }
        func height(_ page: PDFPage) -> CGFloat { page.characterBounds(at: 0).height }
        let smallPage = try await sampler.firstPage(for: small)
        let largePage = try await sampler.firstPage(for: large)
        #expect(height(largePage) > height(smallPage) * 2.5)
        #expect(sampler.drawCount == 2)
        _ = try await sampler.firstPage(for: small)
        #expect(sampler.drawCount == 2)
    }

    @Test("書体を持ち込むテーマへ替えた見本は、その書体が読み込まれてから描く", .timeLimit(.minutes(1)))
    func waitsForTheFontsAThemeBrings() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let latex = try #require(PrintThemeLibrary.load().first { $0.id == "latex" })
        let sampler = try sampler("# Title\n\nThe quick brown fox.", theme: standard)
        defer { sampler.close() }
        _ = try await sampler.firstPage(for: standard)
        let page = try await sampler.firstPage(for: latex)
        // The sampler keeps the page, not its document; a document of its own reads the fonts it embeds.
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdf = String(decoding: try #require(document.dataRepresentation()), as: UTF8.self)
        #expect(pdf.contains("+KaTeX_Main-Regular"))
    }

    @Test("飾りつきのテーマから飾りのないテーマへ替えると、飾りは残らない", .timeLimit(.minutes(1)))
    func dropsDecorationsOfThePreviousTheme() async throws {
        let shows = "h1[data-deco]::before { content: \"<\" attr(data-deco) \">\"; }"
        let decorated = theme("decorated", css: shows, script: "document.querySelector('h1').dataset.deco = 'deco';")
        let plain = theme("plain", css: shows)
        let sampler = try sampler("# Heading", theme: plain)
        defer { sampler.close() }
        #expect(try await sampler.firstPage(for: decorated).string?.contains("<deco>") == true)
        #expect(try await sampler.firstPage(for: plain).string?.contains("deco") == false)
    }

    @Test("最初の読み込みを途中で取り消しても、次の要求は文書を読み込み直して描く", .timeLimit(.minutes(1)))
    func cancelledFirstLoadIsNotReused() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler("# 取り消しのあとの見本", theme: standard)
        defer { sampler.close() }
        let first = Task { @MainActor in _ = try await sampler.firstPage(for: standard) }
        first.cancel()
        _ = await first.result
        let page = try await sampler.firstPage(for: standard)
        #expect(page.string?.contains("取り消しのあとの見本") == true)
    }

    @Test("テーマを使わない形式には見本を作らず、閉じた見本はそれ以上描かない")
    func noSamplerForUnthemedFormatsAndNoneAfterClosing() async throws {
        let standard = theme("standard", css: "")
        let settings = RenderSettings(
            layout: .a4Single, theme: standard, preset: HTMLCleanupPreset(id: "none", name: "None"))
        for format in [DocumentFormat.pdf, .image, .html] {
            #expect(
                try DocumentRenderer.themeSampler(for: DocumentSource(data: Data(), format: format), settings: settings)
                    == nil)
        }
        let sampler = try sampler("x", theme: standard)
        sampler.close()
        await #expect(throws: ThemeSampler.SamplingError.closed) { _ = try await sampler.firstPage(for: standard) }
    }
}
