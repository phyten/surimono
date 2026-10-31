import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

/// A page drawn into a bitmap over a ground of one color, read by points from the page's top left corner.
@MainActor
struct PagePixels {
    let scale: CGFloat = 4
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ page: PDFPage, ground: CGColor = CGColor(gray: 1, alpha: 1)) throws {
        let box = page.bounds(for: .cropBox)
        width = Int(box.width * scale)
        height = Int(box.height * scale)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(ground)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        let data = try #require(context.data)
        // The first row in memory is the top of the image.
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func color(atX x: CGFloat, y: CGFloat) -> (red: Int, green: Int, blue: Int) {
        let index = (min(Int(y * scale), height - 1) * width + min(Int(x * scale), width - 1)) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// The smallest rectangle, in points, around the pixels that `matches` accepts.
    func bounds(where matches: (Int, Int, Int) -> Bool) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                guard matches(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])) else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale)
    }
}

@MainActor
struct PaperBackgroundRenderingTests {
    private func render(
        _ markdown: String, theme: PrintTheme, margin: Double = 15, textScale: Double = 1
    ) async throws -> PDFDocument {
        _ = NSApplication.shared
        var settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.options.marginsInMillimeters = margin
        settings.textScale = textScale
        return try await DocumentRenderer().render(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings
        ).logicalDocument
    }

    private func builtIn(_ id: String) throws -> PrintTheme {
        try #require(PrintThemeLibrary.load().first { $0.id == id })
    }

    private func isClose(_ color: (red: Int, green: Int, blue: Int), to expected: (Int, Int, Int)) -> Bool {
        abs(color.red - expected.0) <= 3 && abs(color.green - expected.1) <= 3 && abs(color.blue - expected.2) <= 3
    }

    @Test("紙のあるテーマは余白まで紙を敷き、本文の下も同じ紙になる", .timeLimit(.minutes(1)))
    func paperCoversTheMargins() async throws {
        let document = try await render("# 星見図書室\n\n本を借りる前に確かめてください。", theme: try builtIn("washi"))
        let pixels = try PagePixels(try #require(document.page(at: 0)))
        let washi = (0xfc, 0xfa, 0xf5)
        // The corner lies in the 15 mm margin; the middle of the page below the short text is inside the text area.
        #expect(isClose(pixels.color(atX: 8, y: 8), to: washi))
        #expect(isClose(pixels.color(atX: 590, y: 838), to: washi))
        #expect(isClose(pixels.color(atX: 300, y: 600), to: washi))
    }

    @Test("飾りのスクリプトが途中で戻っても、テーマの紙は余白まで敷く", .timeLimit(.minutes(1)))
    func decorationsThatReturnKeepThePaper() async throws {
        let theme = PrintTheme(
            id: "early", name: "Early", css: "html { background: #fcfaf5; } body { background: transparent; }",
            script: "return 1;")
        let document = try await render("# x", theme: theme)
        let pixels = try PagePixels(try #require(document.page(at: 0)))
        #expect(isClose(pixels.color(atX: 8, y: 8), to: (0xfc, 0xfa, 0xf5)))
    }

    @Test("紙のないテーマは余白に何も敷かない", .timeLimit(.minutes(1)))
    func plainThemesLeaveTheMarginsWhite() async throws {
        let document = try await render("# 星見図書室", theme: try builtIn("standard"))
        let pixels = try PagePixels(try #require(document.page(at: 0)), ground: CGColor(gray: 0, alpha: 1))
        // Nothing is drawn in the margin, so the black ground shows through and the sheet stays white.
        #expect(isClose(pixels.color(atX: 8, y: 8), to: (0, 0, 0)))
    }

    @Test(
        "紙の模様は余白でも本文の左上を起点にそろう", .timeLimit(.minutes(1)),
        arguments: [(15.0, 1.0), (30.0, 1.5)])
    func patternStartsAtTheTextArea(margin: Double, textScale: Double) async throws {
        // A blue square at the corner of each tile of the paper, and a smaller red one at the start of the text.
        let tile =
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='200'%3E"
            + "%3Crect width='20' height='20' fill='blue'/%3E%3C/svg%3E\")"
        let theme = PrintTheme(
            id: "tiles", name: "Tiles",
            css: """
                html { background: #fff \(tile); -webkit-print-color-adjust: exact; print-color-adjust: exact; }
                body { margin: 0; background: transparent; }
                h1 { margin: 0; width: 5px; height: 5px; overflow: hidden; font-size: 1px; color: transparent;
                    background: red; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
                """)
        let document = try await render("# x", theme: theme, margin: margin, textScale: textScale)
        let pixels = try PagePixels(try #require(document.page(at: 0)))
        let red = try #require(pixels.bounds { $0 > 200 && $1 < 60 && $2 < 60 })
        let blue = try #require(pixels.bounds { $0 < 60 && $1 < 60 && $2 > 200 })
        let points = CGFloat(margin * 72 / 25.4)
        #expect(abs(red.minX - points) < 1 && abs(red.minY - points) < 1)
        #expect(abs(blue.minX - red.minX) < 1 && abs(blue.minY - red.minY) < 1)
    }

    @Test("宿題ノートのテーマは本文のまわりも黒くならない", .timeLimit(.minutes(1)))
    func homeworkPaperIsNotBlack() async throws {
        let document = try await render("# 宿題\n\n今日の宿題です。", theme: try builtIn("homework"))
        let pixels = try PagePixels(try #require(document.page(at: 0)))
        for (x, y) in [(8.0, 8.0), (300.0, 600.0), (590.0, 838.0)] {
            let color = pixels.color(atX: x, y: y)
            #expect(min(color.red, color.green, color.blue) > 200)
        }
    }

    @Test("紙を敷いても文字とリンクは残り、文書の中へのリンクは同じ文書のページを指す", .timeLimit(.minutes(1)))
    func paperKeepsTextAndLinks() async throws {
        let markdown = "# 星見図書室\n\n[案内](https://example.com/)を読んでください[^1]。\n\n[^1]: 開館は九時です。"
        let document = try await render(markdown, theme: try builtIn("washi"))
        let page = try #require(document.page(at: 0))
        #expect(page.string?.contains("案内を読んでください") == true)
        let links = page.annotations.filter { $0.type == "Link" }
        #expect(links.contains { $0.url?.absoluteString == "https://example.com/" })
        let destinations = links.compactMap { $0.destination ?? ($0.action as? PDFActionGoTo)?.destination }
        #expect(!destinations.isEmpty)
        #expect(destinations.allSatisfy { $0.page?.document === document })
    }

    @Test("下地を敷かない組版は、背景のないページを透明のまま描く", .timeLimit(.minutes(1)))
    func clearPagesStayClear() async throws {
        _ = NSApplication.shared
        #expect(WebPaginator.drawsClearPages)
        // WebKit puts its white under the root's box, which the body makes 200 px tall.
        let html = """
            <!doctype html><html style="background: none"><body style="margin: 0; height: 200px"><p>x</p></body></html>
            """
        func colorInsideTheRoot(drawsBackground: Bool) async throws -> (red: Int, green: Int, blue: Int) {
            let result = try await WebPaginator().paginateWithResult(
                .html(html, baseURL: nil), pageSize: CGSize(width: 300, height: 300),
                margins: .uniform(millimeters: 10), allowsJavaScript: false, drawsBackground: drawsBackground)
            let pixels = try PagePixels(try #require(result.document.page(at: 0)), ground: CGColor(gray: 0, alpha: 1))
            return pixels.color(atX: 150, y: 120)
        }
        #expect(isClose(try await colorInsideTheRoot(drawsBackground: false), to: (0, 0, 0)))
        #expect(isClose(try await colorInsideTheRoot(drawsBackground: true), to: (255, 255, 255)))
    }

    /// Collects what the renderer asks the paginator for.
    @MainActor
    private final class Requests {
        var all: [PaginationRequest] = []

        func html(_ index: Int) -> String? {
            guard all.indices.contains(index), case .html(let html, _) = all[index].source else { return nil }
            return html
        }
    }

    private func requests(answering answer: String) async throws -> Requests {
        _ = NSApplication.shared
        let requests = Requests()
        let renderer = DocumentRenderer(paginateWithResult: { request in
            requests.all.append(request)
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: answer)
        })
        let settings = RenderSettings(
            layout: .a4Single, theme: try builtIn("washi"), preset: HTMLCleanupPreset(id: "none", name: "None"))
        _ = try await renderer.render(DocumentSource(data: Data("# x".utf8), format: .markdown), settings: settings)
        return requests
    }

    @Test("紙があると答えたテーマは、本文を紙も下地もなしで組んでから、紙だけを余白なしで組む")
    func paperIsLaidOutOnAPageOfItsOwn() async throws {
        let requests = try await requests(answering: "paper")
        #expect(requests.all.count == 2)
        #expect(requests.all.first?.drawsBackground == false)
        #expect(requests.html(0)?.contains("<style id=\"surimono-paper\">") == true)
        #expect(requests.all.first?.margins == .uniform(millimeters: 15))
        #expect(requests.all.last?.margins == .uniform(millimeters: 0))
        #expect(requests.html(1)?.contains("<body class=\"surimono format-markdown\"></body>") == true)
    }

    @Test("紙がないと答えたテーマは、紙の版を組まない")
    func noPaperNoPaperPage() async throws {
        #expect(try await requests(answering: "").all.count == 1)
    }

    private func renderFailingPaper(with error: any Error) async throws -> PDFDocument {
        _ = NSApplication.shared
        let requests = Requests()
        let renderer = DocumentRenderer(paginateWithResult: { request in
            requests.all.append(request)
            if requests.all.count == 2 { throw error }
            return WebPaginator.Result(document: try RenderingFixtures.pdf(), preparationResult: "paper")
        })
        let settings = RenderSettings(
            layout: .a4Single, theme: try builtIn("washi"), preset: HTMLCleanupPreset(id: "none", name: "None"))
        return try await renderer.render(
            DocumentSource(data: Data("# x".utf8), format: .markdown), settings: settings
        ).logicalDocument
    }

    @Test("紙だけの組版に失敗しても、本文のページは返す")
    func failedPaperKeepsTheText() async throws {
        let document = try await renderFailingPaper(with: WebPaginator.PaginationError.timedOut)
        #expect(document.pageCount == 1)
    }

    @Test("紙だけの組版が取り消されたら、組版ごと取り消す")
    func cancelledPaperCancelsTheRender() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await renderFailingPaper(with: CancellationError())
        }
    }
}
