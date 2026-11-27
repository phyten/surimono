import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct PrintedFrameEdgeTests {
    // Color only the two outer sides. Neither an inner rule, a cell fill, nor text at
    // the margin can stand in for a missing side. The theme still owns style and width.
    private static let colors = """
        table, tr, thead, tbody, td:dir(ltr):first-child, td:dir(rtl):last-child,
        th:dir(ltr):first-child, th:dir(rtl):last-child, pre {
          border-left-color: #ff00ff !important;
        }
        table, tr, thead, tbody, td:dir(ltr):last-child, td:dir(rtl):first-child,
        th:dir(ltr):last-child, th:dir(rtl):first-child, pre {
          border-right-color: #00ffff !important;
        }
        """
    private static let phrase = String(repeating: "内容を確かめる ", count: 16)
    private static let markdown = "| 番号 | 項目 | 内容 |\n|---|---|---|\n| 1 | 項目 | \(phrase) |"

    private struct Ink {
        var left = 0
        var right = 0
        var leftCoverage = 0
        var rightCoverage = 0
        var topRule: ClosedRange<Int>?
        var bottomRule: ClosedRange<Int>?
        var leftX = 0
        var rightX = 0
        /// Pixels that are not paper, so a blank sheet cannot pass as a table without rules.
        var drawn = 0
    }

    /// Count colored pixels per column in a strip of the logical PDF, on white at 144 dpi.
    private func ink(_ page: PDFPage, topOnly: Bool = false, booktabs: Bool = false) throws -> Ink {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * 2))
        let height = Int(ceil((topOnly ? min(bounds.height, 150) : bounds.height) * 2))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height) - 2 * bounds.maxY)
        context.scaleBy(x: 2, y: 2)
        page.draw(with: .mediaBox, to: context)
        defer { withExtendedLifetime(context) {} }
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var left = [Int](repeating: 0, count: width)
        var right = left
        var result = Ink()
        for y in stride(from: 0, to: height, by: booktabs ? 1 : 2) {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let red = Int(pixels[i])
                let green = Int(pixels[i + 1])
                let blue = Int(pixels[i + 2])
                if min(red, green, blue) < 200 { result.drawn += 1 }
                let magenta = min(red, blue) - green
                let cyan = min(green, blue) - red
                if magenta > 32 && abs(red - blue) < 20 {
                    left[x] += 1
                    result.leftCoverage += magenta
                }
                if cyan > 32 && abs(green - blue) < 20 {
                    right[x] += 1
                    result.rightCoverage += cyan
                }
                if booktabs {
                    if red - max(green, blue) > 40 {
                        result.topRule =
                            min(result.topRule?.lowerBound ?? x, x)...max(result.topRule?.upperBound ?? x, x)
                    }
                    if green - max(red, blue) > 40 {
                        result.bottomRule =
                            min(result.bottomRule?.lowerBound ?? x, x)...max(result.bottomRule?.upperBound ?? x, x)
                    }
                }
            }
        }
        result.leftX = try #require(left.indices.max { left[$0] < left[$1] })
        result.rightX = try #require(right.indices.max { right[$0] < right[$1] })
        result.left = left[result.leftX]
        result.right = right[result.rightX]
        return result
    }

    private func check(_ ink: Ink, id: String, requiresFrame: Bool) {
        let detail = "\(id) 左 \(ink.left) (x=\(ink.leftX)) 右 \(ink.right) (x=\(ink.rightX))"
        if requiresFrame { #expect(ink.left >= 6, Comment(rawValue: detail)) }
        if ink.left >= 6 {
            #expect(ink.right >= ink.left / 2 && ink.rightX > ink.leftX, Comment(rawValue: detail))
        }
    }

    private func printed(
        _ source: String, theme: PrintTheme, format: DocumentFormat = .markdown,
        layout: PrintLayout = .a4Single, css: String = "", code: CodeStyle = .init()
    ) async throws -> PDFDocument {
        _ = NSApplication.shared
        let markedTheme = PrintTheme(
            id: theme.id, name: theme.name, css: theme.css + "\n" + Self.colors + "\n" + css,
            isBuiltIn: theme.isBuiltIn, category: theme.category, formats: theme.formats, script: theme.script,
            flow: theme.flow)
        var settings = RenderSettings(
            layout: layout, theme: markedTheme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.code = code
        return try await DocumentRenderer().prepare(
            DocumentSource(data: Data(source.utf8), format: format), settings: settings
        ).logicalDocument
    }

    private func standard() throws -> PrintTheme {
        try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
    }

    @Test("全スタイルで本文幅の表に左外罫があれば右外罫も刷る", .timeLimit(.minutes(1)))
    func catalog() async throws {
        _ = NSApplication.shared
        let themes = try PrintThemeLibrary.load()
        let fragment = MarkdownConverter.convert(Self.markdown)
        let html = HTMLDocumentBuilder.build(
            fragment: fragment, format: .markdown, theme: try standard(), finish: Self.colors)
        let source = WebPaginator.Source.html(html, baseURL: nil)
        // The fractional printable width exposes truncation even on a 1x display.
        let session = PaginationSession(
            source: source, pageSize: PrintLayout.a4Single.logicalPageSize,
            margins: .init(top: 42, left: 42.2, bottom: 42, right: 42.2),
            allowsJavaScript: false, printsBackgrounds: true, printTimeout: .seconds(10),
            onPrintStart: { _ in }, onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        _ = try await session.loadForPrinting(source, timeout: .seconds(10), expireAfterCommit: nil)
        for theme in themes {
            if theme.flow == .vertical {
                let pdf = try await printed(Self.markdown, theme: theme)
                check(try ink(#require(pdf.page(at: 0))), id: theme.id, requiresFrame: true)
                continue
            }
            if theme.formats == [.latex] {
                let slides = theme.id == PrintThemeLibrary.slideStyleID
                let table = "\\begin{tabular}{|l|p{0.65\\linewidth}|}A & \(Self.phrase) \\\\ \\end{tabular}"
                let body = slides ? "\\begin{frame}\(table)\\end{frame}" : table
                let tex = "\\documentclass{\(slides ? "beamer" : "article")}\\begin{document}\(body)\\end{document}"
                let pdf = try await printed(
                    tex, theme: theme, format: .latex, css: "table.latex-tabular { width: 100% }")
                check(try ink(#require(pdf.page(at: 0))), id: theme.id, requiresFrame: true)
                continue
            }
            // The style picker captures screen media. Reuse the loaded view, but run a native print for each sheet.
            _ = try await session.webView.evaluateForPrinting(
                """
                document.querySelector('style').textContent = css;
                """, arguments: ["css": HTMLDocumentBuilder.styleSheet(theme: theme)],
                until: .now + .seconds(10))
            func sheet(protect: Bool) async throws -> Ink {
                let bytes = try await session.printToPDF(checkingBelowPaper: false, protectsFrameEdges: protect)
                let document = try #require(PDFDocument(data: bytes))
                return try ink(#require(document.page(at: 0)), topOnly: true)
            }
            let reference = try await sheet(protect: false)
            let protected = try await sheet(protect: true)
            // PDFKit's text extraction is not dependable on every system, so look at the sheet itself.
            try #require(protected.drawn > 0, "\(theme.id) の表の本文")
            check(protected, id: theme.id, requiresFrame: theme.id == "standard" || reference.left >= 6)
        }
    }

    @Test("標準スタイルの折り返す表は本文幅いっぱいに左右の罫を刷る", .timeLimit(.minutes(1)))
    func fullWidth() async throws {
        let pdf = try await printed(Self.markdown, theme: standard())
        let page = try #require(pdf.page(at: 0))
        let sides = try ink(page)
        check(sides, id: "standard", requiresFrame: true)
        // A clipped but still faintly visible rule has the right height. Compare its ink as well.
        #expect(
            sides.rightCoverage >= sides.leftCoverage * 3 / 4,
            "standard 左 \(sides.leftCoverage) 右 \(sides.rightCoverage)")
        let width = page.bounds(for: .mediaBox).width
        let margin = 15.0 * 72 / 25.4
        #expect(abs(Double(sides.leftX) / 2 - margin) < 2)
        #expect(abs(Double(sides.rightX) / 2 - (width - margin)) < 2)
    }

    @Test("短い表は内容の幅のまま両端を閉じる", .timeLimit(.minutes(1)))
    func narrow() async throws {
        let pdf = try await printed("| a | b |\n|---|---|\n| 1 | 2 |", theme: standard())
        let sides = try ink(#require(pdf.page(at: 0)))
        check(sides, id: "short", requiresFrame: true)
        #expect(sides.rightX - sides.leftX < 150)
    }

    @Test("右から左に読む表も両端の罫を刷る", .timeLimit(.minutes(1)))
    func rightToLeft() async throws {
        let source = "| رقم | نص |\n|---|---|\n| واحد | " + String(repeating: "مرحبا بالعالم ", count: 22) + " |"
        let theme = try standard()
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert(source), format: .markdown, theme: theme)
        try #require(html.contains("dir=\"rtl\""))
        let pdf = try await printed(source, theme: theme)
        check(try ink(#require(pdf.page(at: 0))), id: "RTL", requiresFrame: true)
    }

    @Test(
        "中綴じと二ページ配置の半裁の論理ページにも左右の罫を刷る", .timeLimit(.minutes(1)),
        arguments: [PrintLayout.a4BookletA5, .a4TwoUp])
    func halfPage(layout: PrintLayout) async throws {
        let pdf = try await printed(Self.markdown, theme: standard(), layout: layout)
        let page = try #require(pdf.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        #expect(abs(size.width - layout.logicalPageSize.width) < 0.1)
        #expect(abs(size.height - layout.logicalPageSize.height) < 0.1)
        check(try ink(page), id: "A5", requiresFrame: true)
    }

    @Test("二ページに続く表は両方のページで左右の罫を刷る", .timeLimit(.minutes(1)))
    func spanning() async throws {
        let rows = String(repeating: "\n| 1 | text |", count: 30)
        let pdf = try await printed(
            "| # | value |\n|---|---|" + rows, theme: standard(),
            css: "table { width: 100%; break-inside: auto; page-break-inside: auto } td { height: 36px }")
        try #require(pdf.pageCount == 2)
        for index in 0..<2 {
            check(try ink(#require(pdf.page(at: index))), id: "page \(index + 1)", requiresFrame: true)
        }
    }

    @Test("LaTeX の表は原稿の縦罫と booktabs の両端を刷る", .timeLimit(.minutes(1)), arguments: ["tabular", "longtable"])
    func tabular(environment: String) async throws {
        let source = #"""
            \documentclass{article}
            \usepackage{booktabs,longtable}
            \begin{document}
            \begin{\#(environment)}{|l|l|}
            \toprule
            A & B \\
            C & D \\
            \bottomrule
            \end{\#(environment)}
            \end{document}
            """#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        let pdf = try await printed(
            source, theme: theme, format: .latex,
            css: """
                table.latex-tabular { width: 100% }
                table .latex-top-heavy::before { border-top-color: #ff0000 !important }
                table .latex-bottom-heavy::after { border-top-color: #00ff00 !important }
                """)
        let page = try #require(pdf.page(at: 0))
        let sides = try ink(page, booktabs: true)
        check(sides, id: "LaTeX", requiresFrame: true)
        for rule in [try #require(sides.topRule), try #require(sides.bottomRule)] {
            #expect(abs(rule.lowerBound - sides.leftX) <= 3)
            #expect(abs(rule.upperBound - sides.rightX) <= 3)
        }
    }

    @Test("本文より広い画像もスタイルの額縁ごと収める", .timeLimit(.minutes(1)))
    func borderedImage() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "pixel" })
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="80"></svg>"#
        let fragment = HTMLFragment(
            body: "<img src='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>")
        let html = HTMLDocumentBuilder.build(
            fragment: fragment, format: .markdown, theme: theme,
            finish: "img { border-left-color: magenta; border-right-color: cyan }")
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: PrintLayout.a4Single.logicalPageSize,
            margins: .uniform(millimeters: 15), allowsJavaScript: false, protectsFrameEdges: true)
        check(try ink(#require(result.document.page(at: 0))), id: "img", requiresFrame: true)
    }

    @Test("コードの細い囲み罫を左右とも刷る", .timeLimit(.minutes(1)))
    func codeBlock() async throws {
        let pdf = try await printed(
            "```\nfirst\nsecond\nthird\n```", theme: standard(), code: CodeStyle(block: CodeBlockOptions(frame: .rule)))
        check(try ink(#require(pdf.page(at: 0))), id: "pre", requiresFrame: true)
    }
}
