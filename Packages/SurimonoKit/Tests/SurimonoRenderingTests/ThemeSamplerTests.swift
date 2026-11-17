import AppKit
import PDFKit
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

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

    @Test("見本の鍵は名前には依存せず、描画内容と寸法と言語に依存する")
    func persistentKey() {
        func make(
            html: String = "<p>Sample</p>", width: CGFloat = 595, margin: Double = 15,
            scale: Double = 1, code: CodeStyle = CodeStyle()
        ) -> ThemeSampler {
            ThemeSampler(
                html: html, baseURL: nil, pageSize: CGSize(width: width, height: 842),
                margins: .uniform(millimeters: margin), textScale: scale, code: code)
        }
        let first = theme("same", css: "body { color: black; }")
        let sample = make()
        let key = sample.cacheKey(for: first, language: "en")
        #expect(key.count == 64)
        #expect(key != sample.cacheKey(for: first, language: "en", sourceHash: "changed source"))
        #expect(key == make().cacheKey(for: first, language: "en"))
        #expect(key == sample.cacheKey(for: PrintTheme(id: "same", name: "Renamed", css: first.css), language: "en"))
        #expect(key != sample.cacheKey(for: first, language: "ja"))
        #expect(key != sample.cacheKey(for: theme("same", css: "body { color: blue; }"), language: "en"))
        #expect(key != sample.cacheKey(for: theme("same", css: first.css, script: "decorate()"), language: "en"))
        #expect(key != make(html: "<p>Changed</p>").cacheKey(for: first, language: "en"))
        #expect(key != make(width: 420).cacheKey(for: first, language: "en"))
        #expect(key != make(margin: 20).cacheKey(for: first, language: "en"))
        #expect(key != make(scale: 1.2).cacheKey(for: first, language: "en"))
        let code = CodeStyle(palette: CodePalette(id: "test", name: "Test", colors: [:], ground: "#eeeeee"))
        #expect(key != make(code: code).cacheKey(for: first, language: "en"))
    }

    // MARK: Places

    /// Enough headings and text for several pages.
    private func longDocument(sections: Int = 30) -> String {
        (1...sections).map { number in
            "## 見出し\(number)番\n\n" + String(repeating: "段落\(number)の本文が続きます。", count: 40) + "\n"
        }.joined(separator: "\n")
    }

    private func firstLine(_ page: PDFPage) -> String {
        (page.string ?? "").components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
    }

    @Test("見出しの箇所を指定すると、1 ページの量が違うテーマでも見本はその見出しから始まる", .timeLimit(.minutes(1)))
    func samplesStartAtTheHeading() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let large = theme("large", css: "body { font-size: 28px; line-height: 2.4; } h2 { margin-top: 3em; }")
        let sampler = try sampler(longDocument(), theme: standard)
        defer { sampler.close() }
        let places = try await sampler.places()
        let place = try #require(places.first { $0.title == "見出し20番" })
        for theme in [standard, large] {
            let page = try await sampler.page(for: theme, at: place)
            #expect(firstLine(page).hasPrefix("見出し20番"))
            #expect(abs(page.bounds(for: .mediaBox).width - 595.3) < 1)
            #expect(abs(page.bounds(for: .mediaBox).height - 841.9) < 1)
        }
    }

    @Test("文書の終わりの見出しでは、見本は同じ大きさのまま下が空く", .timeLimit(.minutes(1)))
    func lastHeadingLeavesThePageOpen() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler(longDocument(sections: 12), theme: standard)
        defer { sampler.close() }
        let place = try #require(try await sampler.places().last)
        let page = try await sampler.page(for: standard, at: place)
        #expect(firstLine(page).hasPrefix("見出し12番"))
        #expect(page.string?.contains("段落11") == false)
        #expect(abs(page.bounds(for: .mediaBox).height - 841.9) < 1)
    }

    @Test("文字の大きさを変えた文書でも、見本は見出しから始まる", .timeLimit(.minutes(1)))
    func scaledTextStartsAtTheHeading() async throws {
        _ = NSApplication.shared
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        var settings = RenderSettings(
            layout: .a4Single, theme: standard, preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.textScale = 1.5
        let sampler = try #require(
            try DocumentRenderer.themeSampler(
                for: DocumentSource(data: Data(longDocument().utf8), format: .markdown), settings: settings))
        defer { sampler.close() }
        let place = try #require(try await sampler.places().first { $0.title == "見出し20番" })
        #expect(firstLine(try await sampler.page(for: standard, at: place)).hasPrefix("見出し20番"))
    }

    @Test("矩形が CSS の zoom を含まない古い WebKit でも、文字の大きさを変えた見本は見出しから始まる", .timeLimit(.minutes(1)))
    func unscaledRectanglesStartAtTheHeading() async throws {
        _ = NSApplication.shared
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        // A theme's script runs in the world that measures the places, so it can stand in for WebKit before Safari 26.4.
        let older = theme(
            "older", css: standard.css,
            script: """
                if (!Element.prototype.leavesOutZoom) {
                    const scaled = Element.prototype.getBoundingClientRect;
                    Element.prototype.leavesOutZoom = true;
                    Element.prototype.getBoundingClientRect = function () {
                        const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
                        const box = scaled.call(this);
                        return new DOMRect(box.x / zoom, box.y / zoom, box.width / zoom, box.height / zoom);
                    };
                }
                """)
        var settings = RenderSettings(
            layout: .a4Single, theme: older, preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.textScale = 1.5
        let sampler = try #require(
            try DocumentRenderer.themeSampler(
                for: DocumentSource(data: Data(longDocument().utf8), format: .markdown), settings: settings))
        defer { sampler.close() }
        let place = try #require(try await sampler.places().first { $0.title == "見出し20番" })
        #expect(firstLine(try await sampler.page(for: older, at: place)).hasPrefix("見出し20番"))
    }

    @Test("利用者の CSS がすべての要素の大きさを変えても、見本は見出しから始まる", .timeLimit(.minutes(1)))
    func stylesOnEveryElementStartAtTheHeading() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let padded = theme(
            "padded",
            css: standard.css + """

                * { padding: 10px !important; border: 2px solid gray !important; min-height: 130px !important; }
                """)
        let sampler = try sampler(longDocument(), theme: padded)
        defer { sampler.close() }
        let place = try #require(try await sampler.places().first { $0.title == "見出し20番" })
        #expect(firstLine(try await sampler.page(for: padded, at: place)).hasPrefix("見出し20番"))
    }

    @Test("見出しとコードの箇所を、文書の順に読み取る", .timeLimit(.minutes(1)))
    func readsThePlaces() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let markdown = """
            # 星見図書室

            ##

            ## {本|ほん}の  借り方

            ```swift

            let book = "銀河鉄道"
            print(book)
            ```

            ### 返し方

            ```
            ラベルを確かめる
            ```
            """
        let sampler = try sampler(markdown, theme: standard)
        defer { sampler.close() }
        #expect(
            try await sampler.places() == [
                SamplePlace(kind: .heading, index: 0, level: 1, title: "星見図書室"),
                SamplePlace(kind: .heading, index: 1, level: 2, title: "本の 借り方"),
                SamplePlace(kind: .heading, index: 2, level: 3, title: "返し方"),
                SamplePlace(kind: .code, index: 0, title: "let book = \"銀河鉄道\""),
                SamplePlace(kind: .code, index: 1, title: "ラベルを確かめる"),
            ])
    }

    @Test("見出しのない文書には、箇所がない", .timeLimit(.minutes(1)))
    func noPlaces() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler("本文だけの文書です。", theme: standard)
        defer { sampler.close() }
        #expect(try await sampler.places().isEmpty)
    }

    @Test("コードの箇所を指定すると、見本はそのコードから始まる", .timeLimit(.minutes(1)))
    func samplesStartAtTheCode() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler(longDocument() + "\n\n```\nlet tail = 1\n```\n", theme: standard)
        defer { sampler.close() }
        let place = try #require(try await sampler.places().first { $0.kind == .code })
        #expect(firstLine(try await sampler.page(for: standard, at: place)).hasPrefix("let tail"))
    }

    @Test("箇所ごとに見本を覚え、同じ箇所はもう一度描かない", .timeLimit(.minutes(1)))
    func keepsSamplesByPlace() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler(longDocument(), theme: standard)
        defer { sampler.close() }
        let places = try await sampler.places()
        _ = try await sampler.firstPage(for: standard)
        _ = try await sampler.page(for: standard, at: places[3])
        _ = try await sampler.page(for: standard, at: places[3])
        _ = try await sampler.page(for: standard, at: places[4])
        _ = try await sampler.firstPage(for: standard)
        #expect(sampler.drawCount == 3)
    }

    @Test("文書にない箇所を指定すると、1 ページ目を描く", .timeLimit(.minutes(1)))
    func unknownPlaceDrawsTheFirstPage() async throws {
        let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let sampler = try sampler(longDocument(), theme: standard)
        defer { sampler.close() }
        let gone = SamplePlace(kind: .heading, index: 500, level: 2, title: "なくなった見出し")
        #expect(firstLine(try await sampler.page(for: standard, at: gone)).hasPrefix("見出し1番"))
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

    @Test("読み込み後に WebContent が終了したら読み込み済みとして扱わない")
    func terminationInvalidatesNavigation() {
        _ = NSApplication.shared
        let view = WKWebView()
        let tracker = NavigationTracker()
        tracker.webView(view, didFinish: nil)
        #expect(tracker.state == .finished)
        tracker.webViewWebContentProcessDidTerminate(view)
        guard case .failed = tracker.state else {
            Issue.record("終了したプロセスを読み込み済みとして扱っている")
            return
        }
    }

    @Test("WebContent の終了後は古い見本を保ち、新しい見本は文書を読み直して描く", .timeLimit(.minutes(1)))
    func reloadsAfterContentProcessTermination() async throws {
        let standard = theme("first", css: "")
        let next = theme("next", css: "body { color: navy; }")
        let sampler = try sampler("# Process recovery", theme: standard)
        defer { sampler.close() }
        let first = try await sampler.firstPage(for: standard)
        let views = NSApp.windows.compactMap { $0.contentView as? WKWebView }
        try #require(!views.isEmpty)
        for view in views { view.navigationDelegate?.webViewWebContentProcessDidTerminate?(view) }
        let page = try await sampler.firstPage(for: next)
        #expect(page.string?.contains("Process recovery") == true)
        #expect(try await sampler.firstPage(for: standard) === first)
        #expect(sampler.drawCount == 2)
        // A terminated web view cannot be reused even if a later PDF request appears to succeed.
        let remaining = NSApp.windows.compactMap { $0.contentView as? WKWebView }
        #expect(!remaining.contains { current in views.contains { $0 === current } })
    }

    @Test("紙の判定が失敗した見本を白紙のテーマとして覚えず、次は新しく読み込む", .timeLimit(.minutes(1)))
    func failedPaperDetectionIsNotCached() async throws {
        let broken = theme(
            "broken", css: "",
            script: "window.getComputedStyle = () => { throw new Error('fixture failure'); };")
        let plain = theme("plain", css: "")
        let sampler = try sampler("# Retry after failure", theme: plain)
        defer { sampler.close() }
        var failed = false
        do { _ = try await sampler.firstPage(for: broken) } catch { failed = true }
        #expect(failed)
        #expect(sampler.drawCount == 0)
        let page = try await sampler.firstPage(for: plain)
        #expect(page.string?.contains("Retry after failure") == true)
        #expect(sampler.drawCount == 1)
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
