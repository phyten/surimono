import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

struct PrintFrameExtensionTests {
    @Test("列数の境界へ乗算で丸め戻される幅とその両隣では補正しない")
    func roundingBoundary() {
        let boundary: Float = 451.999
        for width in [boundary.nextDown, boundary, boundary.nextUp] {
            let columns = floor(width * 1.25)
            #expect(columns == 564)
            #expect(
                PrintFrameExtension.calculate(width: width, height: 300, firstScroll: columns, fittedScroll: columns)
                    == nil)
        }
        #expect(((567 / Float(1.25)).nextDown * 1.25) == 567)
    }

    @Test("拡張できる幅は再計算した列数・倍率・一ページの行数が一致する", arguments: [625, 800, 999, 1000, 1001])
    func extensionGeometry(scrollWidth: Int) throws {
        let width: Float = 500
        let height: Float = 300
        let fitted = Float(min(scrollWidth, 1000))
        let plan = try #require(
            PrintFrameExtension.calculate(
                width: width, height: height, firstScroll: Float(scrollWidth), fittedScroll: Float(scrollWidth)))
        let columns = floor(plan.width * 1.25)
        let actual = min(max(columns, plan.minimumWidth), floor(columns * 1.6))
        #expect(actual - plan.padding == fitted)
        #expect(plan.width / actual == width / fitted)
        #expect(floor(actual * (height / plan.width)) == floor(fitted * (height / width)))
    }

    @Test("列数が合っても元の倍率または一ページの高さを再現できない候補を除く")
    func scaleAndHeightBoundaries() throws {
        let width: Float = 510.87558
        let scale = width / 638
        #expect((scale * 640) / 640 != scale)
        let plan = try #require(
            PrintFrameExtension.calculate(width: width, height: 300, firstScroll: 638, fittedScroll: 638))
        #expect(plan.padding == 3)
        #expect(plan.width / 641 == scale)

        // At this height both candidates lose the last row of the logical page.
        #expect(PrintFrameExtension.calculate(width: 500, height: 306.4, firstScroll: 625, fittedScroll: 625) == nil)
    }

    @Test("独自スタイルの印刷要求では本文の描画範囲を広げない", arguments: [true, false])
    @MainActor func themeEligibility(builtIn: Bool) async throws {
        let theme = PrintTheme(id: "sample", name: "Sample", css: "td { color: black }", isBuiltIn: builtIn)
        let renderer = DocumentRenderer(paginate: { request in
            #expect(request.protectsFrameEdges == builtIn)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        let settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        _ = try await renderer.prepare(
            DocumentSource(data: Data("A paragraph.".utf8), format: .markdown), settings: settings)
    }

    enum Layout: CaseIterable {
        case standard, zeroMargins, wide, beforeLimit, atLimit, overLimit, wideRTL, latexMarginInk
        case roundingBoundary, fixedRoot, cappedRoot, paddedRoot, pageRule, unreadableSheet, embeddedStyle,
            viewportLength

        var margins: WebPaginator.Margins {
            switch self {
            case .latexMarginInk: .init(top: 20, left: 80, bottom: 20, right: 0)
            case .zeroMargins: .uniform(millimeters: 0)
            case .standard, .wide: .uniform(millimeters: 15)
            default: .init(top: 20, left: 42.5, bottom: 20, right: 42.5)
            }
        }
        var paper: CGSize {
            switch self {
            case .standard, .zeroMargins, .wide: PrintLayout.a4Single.logicalPageSize
            case .latexMarginInk: CGSize(width: 600, height: 340)
            case .roundingBoundary: CGSize(width: 451.999 + 85, height: 340)
            default: CGSize(width: 585, height: 340)
            }
        }
        var css: String {
            switch self {
            case .beforeLimit: "table { min-width: 999px }"
            case .atLimit: "table { min-width: 1000px }"
            case .overLimit: "table { min-width: 1001px }"
            case .wide, .wideRTL: "table { min-width: 800px }"
            case .latexMarginInk: "table { min-width: 700px }"
            case .fixedRoot: "@media print { html { width: 400px } }"
            case .cappedRoot: "html { max-inline-size: 430px; padding: 0 8px }"
            case .paddedRoot: "html { padding-inline: 2% 3% }"
            case .pageRule: "@media print { @page { margin: 15mm } }"
            default: ""
            }
        }

        var expectsOriginalClip: Bool {
            switch self {
            case .fixedRoot, .cappedRoot, .paddedRoot, .pageRule, .unreadableSheet, .embeddedStyle, .viewportLength,
                .roundingBoundary, .latexMarginInk:
                true
            default: false
            }
        }
    }

    @Test("右罫の補正の有無でページ数・全ページの画素・全リンクが一致する", .timeLimit(.minutes(1)), arguments: Layout.allCases)
    @MainActor func wholeDocument(layout: Layout) async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let words = String(repeating: layout == .wideRTL ? "مرحبا بالعالم " : "Words near the page break ", count: 7)
        let paragraphs = 1...16
        let text = paragraphs.map { "\(words) [link-\($0)](https://example.org/\($0)) \(words)" }.joined(
            separator: "\n\n")
        let source =
            "A [$x^2$](https://example.org/math).\n\n\\[\\frac{A}{B}\\]\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n" + text
        // Keep the corrected edge free of ink so every pixel, including the margins, can be compared.
        // In fallback cases put ink there as well: those pages must retain their original clip.
        let css = """
            table { width: 100%; margin: 0 } table, th, td { border: 0 }
            p, td { padding-inline: 10px }
            \(layout.expectsOriginalClip ? "table { border-right: 1px solid black }" : "")
            \(layout.css)
            """
        var fragment = MarkdownConverter.convert(source)
        if layout == .wideRTL { fragment.language = "ar" }
        if layout == .embeddedStyle {
            fragment.body += "<style>@media (min-width: 626px) { p { color: red } }</style>"
        } else if layout == .viewportLength {
            fragment.body = fragment.body.replacingOccurrences(of: "<p>", with: "<p style='text-indent: 20vw'>")
        }
        let html = HTMLDocumentBuilder.build(fragment: fragment, format: .markdown, theme: theme, finish: css)
        // Simulate an unreadable CSSOM in the same isolated world as the page-rule probe.
        let unreadable =
            "Object.defineProperty(document, 'styleSheets', {get() { throw new DOMException('Denied', 'SecurityError'); }});"
        func document(protect: Bool) async throws -> PDFDocument {
            let paginator = WebPaginator()
            if layout == .pageRule || layout == .unreadableSheet {
                paginator.didCheckPageRules = { mayHaveRules in #expect(mayHaveRules) }
            }
            return try await paginator.paginateWithResult(
                .html(html, baseURL: nil), pageSize: layout.paper, margins: layout.margins, allowsJavaScript: false,
                preparationScript: layout == .unreadableSheet ? unreadable : nil,
                latexMarginInk: layout == .latexMarginInk, protectsFrameEdges: protect
            ).document
        }
        let before = try await document(protect: false)
        let after = try await document(protect: true)
        try #require(before.pageCount >= 2 && after.pageCount == before.pageCount)
        var linkedPages = 0
        var urls: Set<String> = []
        for index in 0..<before.pageCount {
            let original = try #require(before.page(at: index))
            let protected = try #require(after.page(at: index))
            let detail = Comment(rawValue: "\(layout) の \(index + 1) ページ目")
            try #require(original.bounds(for: .mediaBox) == protected.bounds(for: .mediaBox), detail)
            #expect(original.bounds(for: .cropBox) == protected.bounds(for: .cropBox), detail)
            let links = try links(on: original)
            #expect(try links == self.links(on: protected), detail)
            if !links.isEmpty { linkedPages += 1 }
            urls.formUnion(links.keys.map(\.url))
            let originalPixels = try pixels(original)
            let protectedPixels = try pixels(protected)
            let identical = originalPixels == protectedPixels
            #expect(identical, detail)
        }
        #expect(linkedPages >= 2)
        #expect(urls == Set(paragraphs.map { "https://example.org/\($0)" } + ["https://example.org/math"]))
    }

    private struct Link: Hashable {
        let url: String
        let bounds: CGRect
    }

    @MainActor private func links(on page: PDFPage) throws -> [Link: Int] {
        var counts: [Link: Int] = [:]
        for annotation in page.annotations where annotation.type == "Link" {
            let url = try #require(annotation.url)
            counts[Link(url: url.absoluteString, bounds: annotation.bounds), default: 0] += 1
        }
        return counts
    }

    @MainActor private func pixels(_ page: PDFPage) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 8
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        let bitmap = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        bitmap.drawPDFPage(try #require(page.pageRef))
        return Data(bytes: try #require(bitmap.data), count: width * height)
    }
}
