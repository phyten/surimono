import AppKit
import JavaScriptCore
import PDFKit
import SurimonoCore
import SurimonoFormats
import Testing
import WebKit

@testable import SurimonoRendering

@MainActor
struct TableFitTests {
    @Test("収まる表は等倍のままで、はみ出す表ははみ出した比率だけ前の倍率から下限なしに縮める")
    func scale() throws {
        let js = try #require(JSContext())
        js.evaluateScript(TableFit.scaleFunction)
        let next = try #require(js.objectForKeyedSubscript("nextScale"))
        #expect(next.call(withArguments: [1, 600, 500]).toDouble() == 1)
        #expect(next.call(withArguments: [1, 600, 800]).toDouble() == 0.75)
        #expect(next.call(withArguments: [0.5, 600, 1200]).toDouble() == 0.25)
        #expect(next.call(withArguments: [1, 240, 2400]).toDouble() == 0.1)
        #expect(js.exception == nil)
    }

    private let paragraph = "# Comparison\n\nSame body size. 本文の大きさを比較します。\n\n"
    private var theme: PrintTheme {
        get throws {
            let standard = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
            // Only the body glyphs are blue. Only the far outside edge of the table is red.
            return PrintTheme(
                id: "table-fit", name: "Table fit",
                css: standard.css + """
                    \np { color: blue }
                    th:last-child, td:last-child { border-right: 5px solid red }
                    """)
        }
    }

    private func printed(
        _ body: String, layout: PrintLayout = .a4Single, fit: Bool = true, css: String = "",
        theme chosen: PrintTheme? = nil, footnotes: FootnotePlacement = .end,
        inspect: (@MainActor (WKWebView) async -> Void)? = nil,
        requested: (@MainActor (PaginationRequest) -> Void)? = nil
    ) async throws -> RenderResult {
        _ = NSApplication.shared
        let renderer = DocumentRenderer(paginateWithResult: { request in
            var request = request
            if !fit { request.fitsTables = false }
            requested?(request)
            let paginator = WebPaginator()
            paginator.inspectPrintLayout = inspect
            return try await paginator.paginate(request)
        })
        let base = try chosen ?? theme
        var settings = RenderSettings(
            layout: layout,
            theme: PrintTheme(
                id: base.id, name: base.name, css: base.css + "\n" + css, category: base.category,
                formats: base.formats, script: base.script, flow: base.flow),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.finish.footnotes = footnotes
        return try await renderer.render(DocumentSource(data: Data(body.utf8), format: .markdown), settings: settings)
    }

    private func printPage(
        _ body: String, fit: Bool = true, css: String = "", theme: PrintTheme? = nil,
        footnotes: FootnotePlacement = .end
    ) async throws -> PDFPage {
        let document = try await printed(body, fit: fit, css: css, theme: theme, footnotes: footnotes)
            .logicalDocument
        try #require(document.pageCount == 1)
        return try #require(document.page(at: 0))
    }

    /// Whether the first table of the printed DOM counts as fitted, so that it is not reported as too wide.
    @MainActor
    private final class Fitted {
        var value = false
        func record(_ view: WKWebView) async {
            let fitted = try? await view.evaluateForPrinting(
                "return globalThis.surimonoFittedTables?.has(document.querySelector('table')) === true",
                until: .now + .seconds(10))
            value = fitted as? Bool == true
        }
    }

    /// What TableFit measured at each step for the first table, and how the table was left, to explain a failure on
    /// a system these tests are not run on here.
    @MainActor
    private final class FitLog {
        var text = ""
        func record(_ view: WKWebView) async {
            let json = try? await view.evaluateForPrinting(
                """
                const t = document.querySelector('table'), css = getComputedStyle(t);
                return JSON.stringify({steps: globalThis.surimonoTableFitLog ?? null, zoom: css.zoom,
                    maxWidth: css.maxWidth, style: t.getAttribute('style'), offsetWidth: t.offsetWidth});
                """, until: .now + .seconds(10))
            text = (json as? String ?? "unavailable") + " on " + ProcessInfo.processInfo.operatingSystemVersionString
        }
    }

    /// Whether the last table of the printed DOM was narrowed by a transform, the last resort.
    @MainActor
    private final class Transformed {
        var value = false
        func record(_ view: WKWebView) async {
            let transform = try? await view.evaluateJavaScript(
                "getComputedStyle([...document.querySelectorAll('table')].at(-1)).transform")
            value = (transform as? String).map { $0 != "none" } ?? false
        }
    }

    private struct Raster {
        let width: Int
        let data: Data
        init(_ page: PDFPage, crop: CGRect? = nil) throws {
            let bounds = crop ?? page.bounds(for: .mediaBox)
            width = Int(ceil(bounds.width * 2))
            let height = Int(ceil(bounds.height * 2))
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(try #require(page.pageRef))
            data = Data(bytes: try #require(context.data), count: width * height * 4)
        }

        /// The first rows of pixels, down to and including `y`.
        func rows(through y: CGFloat) -> Data { data.prefix((Int(y) + 1) * width * 4) }

        /// The pixels inside `rect`, row by row.
        func pixels(in rect: CGRect) -> [UInt8] {
            var result: [UInt8] = []
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let start = (y * width + Int(rect.minX)) * 4
                result += data[start..<start + Int(rect.width) * 4]
            }
            return result
        }

        /// Row numbers read from the row markers, top to bottom: a marker of blue 30 + 3n marks row n. The edges of
        /// a marker blend with the paper and are not pure blue, so only its inside is read.
        func markers() -> [Int] {
            let height = data.count / 4 / width
            var result: [Int] = []
            var levels: [Int: Int] = [:]
            func close() {
                guard let level = levels.max(by: { $0.value < $1.value })?.key else { return }
                result.append(Int((Double(level - 30) / 3).rounded()))
                levels = [:]
            }
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    var found = false
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        if bytes[i] < 16 && bytes[i + 1] < 16 && bytes[i + 2] > 20 {
                            levels[Int(bytes[i + 2]), default: 0] += 1
                            found = true
                        }
                    }
                    if !found { close() }
                }
            }
            close()
            return result
        }

        func bounds(channel: Int) throws -> CGRect {
            let box = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var left = width
                var right = -1
                var top = Int.max
                var bottom = -1
                for i in stride(from: 0, to: bytes.count, by: 4)
                where bytes[i + channel] > 160 && bytes[i + (channel + 1) % 3] < 80 && bytes[i + (channel + 2) % 3] < 80
                {
                    let x = i / 4 % width
                    let y = i / 4 / width
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
                return right < left
                    ? CGRect.null : CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            }
            try #require(!box.isNull)
            return box
        }
    }

    @Test("折り返し禁止のセルは等倍で全文を刷り、折り返しを許した対照と全画素が一致する", .timeLimit(.minutes(1)))
    func nowrapAtFullSize() async throws {
        // The explicit 90% track leaves room for the outside stroke in both PDFs.
        // Only the nowrap version exceeds the column before preparation.
        let table =
            "<table style='width:90%;box-sizing:border-box'><tr><td style='white-space:nowrap!important'>"
            + String(repeating: "折り返さない長いセル。", count: 20)
            + "<span style='color:lime'>末尾</span></td><td>b</td></tr></table>"
        let reference = try await Raster(
            printPage(paragraph + table.replacingOccurrences(of: "nowrap", with: "normal"), fit: false))
        let fitted = try await Raster(printPage(paragraph + table))
        #expect(fitted.data == reference.data)
        let tail = try fitted.bounds(channel: 1)
        let border = try fitted.bounds(channel: 0)
        #expect(tail.width > 4 && tail.maxX < border.minX)
    }

    private func wideTable(rows: Int) -> String {
        func row(_ cells: [String]) -> String { "|" + cells.joined(separator: "|") + "|\n" }
        let head = row((1...40).map { "c\($0)" }) + row(Array(repeating: "---", count: 40))
        return head
            + (0..<rows).map { index in
                // Each row starts with a marker whose blue gives its number, so a lost, repeated or reordered
                // row shows. A single glyph in the outside column measures its printed type independently of
                // the border.
                let marker =
                    "<span style='display:inline-block;width:10px;height:10px;background:rgb(0,0,\(30 + 3 * index))'>"
                    + "</span>"
                return row([marker] + (2..<40).map(String.init) + ["<span style='color:lime'>H</span>"])
            }.joined()
    }

    @Test("40列表だけを縮めて最後の列を刷り、外罫と本文の右端の間に余裕を残す", .timeLimit(.minutes(1)))
    func fortyColumns() async throws {
        let lead = "# Comparison\n\n<span style='color:blue'>H</span>\n\n"
        let control = try await Raster(printPage(lead))
        let page = try await printPage(lead + wideTable(rows: 1))
        let actual = try Raster(page)
        let body = try control.bounds(channel: 2)
        // Heading and body text, everything above the table, are the same pixels as without the table.
        #expect(actual.rows(through: body.maxY + 4) == control.rows(through: body.maxY + 4))
        let last = try actual.bounds(channel: 1)
        let border = try actual.bounds(channel: 0)
        #expect(last.height < body.height && last.maxX <= border.minX)
        checkOutsideRule(border, pageWidth: page.bounds(for: .mediaBox).width)
    }

    /// Prints with web views of the given device scale: CI's screen is not Retina, and zoomed rules and rounded
    /// offsets come out differently there.
    private func atDeviceScale<T>(_ scale: CGFloat, _ body: () async throws -> T) async throws -> T {
        let selector = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        try #require(WKWebView.instancesRespond(to: selector))
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        PaginationSession.prepareForTesting = { view in
            unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, scale)
        }
        defer { PaginationSession.prepareForTesting = nil }
        return try await body()
    }

    @Test(
        "右から左に読む40列表も表だけを縮め、両端の外罫を本文の幅の中に刷り、収まった表として扱う", .timeLimit(.minutes(1)),
        arguments: [1.0, 2.0])
    func rightToLeft(scale: Double) async throws {
        func row(_ cells: [String]) -> String { "|" + cells.joined(separator: "|") + "|\n" }
        let lead = "مرحبا بالعالم\n\n"
        let table =
            row((1...40).map { "عمود\($0)" }) + row(Array(repeating: "---", count: 40))
            + row((1...40).map { "ق\($0)" })
        // Both outside rules are red here; the right one of the theme above marks an inner rule in this direction.
        // They are thick enough to stay wider than the cells' rules once zoomed and rounded to a device pixel, so
        // they win where they meet.
        let css =
            "th:last-child, td:last-child { border-right: 1px solid black !important } "
            + "table { border-left: 12px solid red !important; border-right: 12px solid red !important }"
        let log = FitLog()
        let fitted = Fitted()
        let (control, result) = try await atDeviceScale(CGFloat(scale)) {
            (
                try await Raster(printPage(lead, css: css)),
                try await printed(
                    lead + table, css: css,
                    inspect: { view in
                        await log.record(view)
                        await fitted.record(view)
                    })
            )
        }
        let page = try #require(result.logicalDocument.page(at: 0))
        let actual = try Raster(page)
        let body = try control.bounds(channel: 2)
        // A page shrunk as a whole moves and narrows the body text; a table off the page loses its rules.
        let detail = Comment(
            rawValue: "scale \(scale), pages \(result.logicalDocument.pageCount), page \(page.bounds(for: .mediaBox)), "
                + "body \(body) → \((try? actual.bounds(channel: 2)) ?? .null): " + log.text)
        #expect(fitted.value, detail)
        #expect(result.issues.isEmpty, detail)
        #expect(actual.rows(through: body.maxY + 4) == control.rows(through: body.maxY + 4), detail)
        let rules = try actual.bounds(channel: 0)
        let margin = 15 * 72 / 25.4 * 2
        let rightEdge = page.bounds(for: .mediaBox).width * 2 - margin
        #expect(rules.minX >= floor(margin) - 1, detail)
        #expect(rules.maxX <= floor(rightEdge) - 1, detail)
        // The table takes the whole column rather than being shrunk with the page.
        #expect(rules.width > rightEdge - margin - 24, detail)
    }

    private func checkOutsideRule(_ border: CGRect, pageWidth: CGFloat) {
        let rightEdge = (pageWidth - 15 * 72 / 25.4) * 2
        #expect(border.minX > rightEdge - 24)
        #expect(border.maxX <= floor(rightEdge) - 1)
        #expect(border.width >= 2 && border.height >= 8)
    }

    @Test(
        "2アップと冊子では半裁の論理ページに合わせ、表の続きにも同じ幅の最終列と外罫を刷る",
        .timeLimit(.minutes(1)), arguments: [PrintLayout.a4TwoUp, .a4BookletA5])
    func continuedTable(layout: PrintLayout) async throws {
        let result = try await printed(wideTable(rows: 75), layout: layout)
        let document = result.logicalDocument
        try #require(document.pageCount >= 2)
        var firstRule: CGRect?
        var markers: [Int] = []
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            try #require(page.bounds(for: .mediaBox).width < 430)
            let pixels = try Raster(page)
            markers += pixels.markers()
            let border = try pixels.bounds(channel: 0)
            let last = try pixels.bounds(channel: 1)
            #expect(last.maxX <= border.minX)
            checkOutsideRule(border, pageWidth: page.bounds(for: .mediaBox).width)
            if let firstRule {
                #expect(abs(border.minX - firstRule.minX) <= 1 && abs(border.width - firstRule.width) <= 1)
            } else {
                firstRule = border
            }
        }
        // Every row is printed once, in order, across the pages.
        #expect(markers == Array(0..<75))
        // Sample each occupied half on the actual imposed sheets, including booklet backs.
        for (index, side) in result.plan.sides.enumerated() {
            let sheet = try #require(result.sheetDocument.page(at: index))
            let size = sheet.bounds(for: .mediaBox).size
            for (slot, logical) in side.slots.enumerated() where logical != nil {
                let crop = CGRect(x: CGFloat(slot) * size.width / 2, y: 0, width: size.width / 2, height: size.height)
                let border = try Raster(sheet, crop: crop).bounds(channel: 0)
                checkOutsideRule(border, pageWidth: crop.width)
            }
        }
    }

    @Test("スタイル見本は本文を同じ大きさに保ち、次のスタイルで表幅を測り直す", .timeLimit(.minutes(1)))
    func palette() async throws {
        _ = NSApplication.shared
        let normal = try theme
        let compact = PrintTheme(
            id: "compact", name: "Compact", css: normal.css + " td { white-space: normal !important; }")
        let table =
            "<table><tr><td style='white-space:nowrap'>" + String(repeating: "長いセル", count: 64) + "</td></tr></table>"
        func sampler(_ body: String) throws -> ThemeSampler {
            let settings = RenderSettings(
                layout: .a4Single, theme: normal, preset: HTMLCleanupPreset(id: "none", name: "None"))
            return try #require(
                try DocumentRenderer.themeSampler(
                    for: DocumentSource(data: Data(body.utf8), format: .markdown), settings: settings))
        }
        let wide = try sampler(paragraph + table)
        let control = try sampler(paragraph)
        let fresh = try sampler(paragraph + table)
        defer {
            wide.close()
            control.close()
            fresh.close()
        }
        let fitted = try await Raster(wide.firstPage(for: normal))
        let plain = try await Raster(control.firstPage(for: normal))
        let body = try plain.bounds(channel: 2)
        #expect(fitted.rows(through: body.maxY + 4) == plain.rows(through: body.maxY + 4))
        let edge = try fitted.bounds(channel: 0)
        let rightEdge = (wide.pageSize.width - wide.margins.right) * 2
        #expect(edge.maxX <= ceil(rightEdge) && edge.minX > rightEdge - 24)
        let switched = try await Raster(wide.firstPage(for: compact))
        let clean = try await Raster(fresh.firstPage(for: compact))
        #expect(switched.data == clean.data)
    }

    @Test("表のない文書と収まる表のある文書は調整の有無でページ全体の画素が一致する", .timeLimit(.minutes(1)), arguments: [false, true])
    func ordinaryPage(hasTable: Bool) async throws {
        let source = hasTable ? paragraph + "| 名前 | URL |\n|---|---|\n| one | two |" : paragraph
        let original = try await Raster(printPage(source, fit: false))
        let fitted = try await Raster(printPage(source))
        #expect(original.data == fitted.data)
    }

    @Test("最後の手段で横に縮めた表も、表の中と後ろの段落は同じスタイルで刷る", .timeLimit(.minutes(1)))
    func lastResortKeepsSelectors() async throws {
        func row(_ cells: [String]) -> String { "|" + cells.joined(separator: "|") + "|\n" }
        let wide =
            row((1...40).map { "c\($0)" }) + row(Array(repeating: "---", count: 40))
            + row((1..<40).map(String.init) + ["H"])
        // Rules that only hold while the table is a child of the body, with the paragraph right after it.
        let css = """
            body > p { color: black } body > table + p { color: blue }
            body > table td:last-child { color: lime }
            """
        let transformed = Transformed()
        let result = try await printed(
            wide + "\nAfter the table\n", layout: .a4TwoUp, css: css, inspect: transformed.record)
        try #require(transformed.value)
        #expect(result.issues.isEmpty)
        let page = try Raster(#require(result.logicalDocument.page(at: 0)))
        let narrow = try await printed("| a |\n|---|\n| H |\n\nAfter the table\n", layout: .a4TwoUp, css: css)
        let control = try Raster(#require(narrow.logicalDocument.page(at: 0)))
        let after = try page.bounds(channel: 2)
        let expected = try control.bounds(channel: 2)
        #expect(after.size == expected.size)
        #expect(page.pixels(in: after) == control.pixels(in: expected))
        let last = try page.bounds(channel: 1)
        let border = try page.bounds(channel: 0)
        #expect(last.maxX <= border.minX && last.maxY < after.minY)
    }

    @Test(
        "向きの違う親の中の表も、最後の手段で縮めて両端の外罫と端のセルを本文の幅の中に刷る", .timeLimit(.minutes(1)),
        arguments: [("ltr", "rtl"), ("rtl", "ltr")])
    func mixedDirections(parent: String, table: String) async throws {
        let ends = "<td><span style='color:lime'>H</span></td>"
        let cells = ends + (2..<40).map { "<td>c\($0)</td>" }.joined() + ends
        let html =
            "<div dir='\(parent)'><table dir='\(table)' style='border-left:5px solid red;border-right:5px solid red'>"
            + "<tr>\(cells)</tr></table></div>\n"
        let transformed = Transformed()
        let result = try await printed(
            // A thinner cell rule loses to the table's outside rule where they meet.
            html, layout: .a4TwoUp, css: "th:last-child, td:last-child { border-right: 1px solid black }",
            inspect: transformed.record)
        try #require(transformed.value)
        #expect(result.issues.isEmpty)
        let page = try #require(result.logicalDocument.page(at: 0))
        let pixels = try Raster(page)
        let rules = try pixels.bounds(channel: 0)
        let margin = 15 * 72 / 25.4 * 2
        let rightEdge = page.bounds(for: .mediaBox).width * 2 - margin
        #expect(rules.minX >= floor(margin) - 1)
        #expect(rules.maxX <= floor(rightEdge) - 1)
        #expect(rules.width > rightEdge - margin - 24)
        let edgeCells = try pixels.bounds(channel: 1)
        #expect(edgeCells.minX > rules.minX && edgeCells.maxX < rules.maxX)
    }

    @Test("最小の幅だけで広い表は、最小の幅を外せば等倍で収まるので縮めない", .timeLimit(.minutes(1)))
    func minimumWidthOnly() async throws {
        let cell = "<td style='border-right:5px solid red'><span style='color:lime'>short text</span></td>"
        let log = FitLog()
        let result = try await printed(
            "<table style='width:1200px;min-width:1200px'><tr>\(cell)</tr></table>\n", inspect: log.record)
        let wide = try Raster(#require(result.logicalDocument.page(at: 0)))
        let narrow = try await Raster(printPage("<table><tr>\(cell)</tr></table>\n"))
        let text = try wide.bounds(channel: 1)
        let expected = try narrow.bounds(channel: 1)
        // Room, the widths after wrapping and after setting the width, the zoom found and the table as printed.
        #expect(text.size == expected.size, Comment(rawValue: log.text))
        #expect(wide.pixels(in: text) == narrow.pixels(in: expected), Comment(rawValue: log.text))
        let pageWidth = PrintLayout.a4Single.logicalPageSize.width
        checkOutsideRule(try wide.bounds(channel: 0), pageWidth: pageWidth)
    }

    @Test("ルートに内側の余白があっても、収まる表は見本と本番のどちらの幅でも変えない", .timeLimit(.minutes(1)), arguments: [nil, 637.5])
    func rootPadding(width: Double?) async throws {
        _ = NSApplication.shared
        let base = try theme
        let padded = PrintTheme(id: base.id, name: base.name, css: base.css + "\nhtml { padding: 0 30px }")
        // The view is 511 pixels wide, so its content is 451; the print's is 577.5. The table fits both.
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<table style='width:440px'><tr><td>fits</td></tr></table>"),
            format: .markdown, theme: padded)
        let source = WebPaginator.Source.html(html, baseURL: nil)
        let session = PaginationSession(
            source: source, pageSize: PrintLayout.a4Single.logicalPageSize, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, printsBackgrounds: true, printTimeout: .seconds(10),
            onPrintStart: { _ in }, onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        _ = try await session.loadForPrinting(source, timeout: .seconds(10), expireAfterCommit: nil)
        let changed = try await TableFit.fit(
            in: session.webView, width: width.map { CGFloat($0) }, until: .now + .seconds(10))
        #expect(!changed)
        let style = try await session.webView.evaluateForPrinting(
            "return document.querySelector('table').getAttribute('style')", until: .now + .seconds(10))
        #expect(style as? String == "width:440px")
    }

    @Test(
        "ルートに内側の余白があり本文の直下で縮める表も、本文の幅の中に刷り、収まった表として扱う", .timeLimit(.minutes(1)),
        arguments: [0, 40])
    func rootPaddingFitted(bodyMargin: Int) async throws {
        let cells = (1...40).map { "<td>c\($0)</td>" }.joined()
        let table = "<table style='border-left:5px solid red'><tr>\(cells)</tr></table>\n"
        let css = "html { padding: 0 30px } body { margin-left: \(bodyMargin)px !important }"
        let fitted = Fitted()
        let result = try await printed(table, css: css, inspect: fitted.record)
        #expect(fitted.value)
        #expect(result.issues.isEmpty)
        let page = try #require(result.logicalDocument.page(at: 0))
        let rules = try Raster(page).bounds(channel: 0)
        // The body's content box, in pixels of the 144 dpi raster: a CSS pixel is 0.8 points.
        let margin = 15 * 72 / 25.4
        let left = (margin + Double(30 + bodyMargin) * 0.8) * 2
        let right = (page.bounds(for: .mediaBox).width - margin - 30 * 0.8) * 2
        #expect(rules.minX >= floor(left) - 1)
        #expect(rules.maxX <= floor(right) - 1)
        #expect(rules.width > right - left - 24)
    }

    @Test("脚注をページの下に置く文書でも表だけを縮め、本文は表のない文書と同じ画素で刷る", .timeLimit(.minutes(1)))
    func pageFootnotes() async throws {
        let lead = "<span style='color:blue'>H</span> with a note[^n].\n\n[^n]: The note.\n\n"
        // Only the marked glyph is blue: the note below the table is a paragraph too.
        let css = "p { color: black }"
        var measured = false
        let control = try await Raster(printPage(lead, css: css, footnotes: .pageBottom))
        let result = try await printed(
            lead + wideTable(rows: 1), css: css, footnotes: .pageBottom,
            requested: { if $0.footnotePass != nil && $0.fitsTables { measured = true } })
        #expect(measured)
        let page = try #require(result.logicalDocument.page(at: 0))
        let actual = try Raster(page)
        let body = try control.bounds(channel: 2)
        #expect(actual.rows(through: body.maxY + 4) == control.rows(through: body.maxY + 4))
        checkOutsideRule(try actual.bounds(channel: 0), pageWidth: page.bounds(for: .mediaBox).width)
    }

    @Test("飾りのスクリプトを持つ組み込みのスタイルでも、本文は表のない文書と同じ画素で、表は本文の幅に収める", .timeLimit(.minutes(1)))
    func decoratedTheme() async throws {
        let decorated = try #require(PrintThemeLibrary.load().first { $0.id == "emoji" })
        try #require(decorated.script?.isEmpty == false)
        let lead = "<span style='color:blue'>H</span> body text.\n\n"
        let cells =
            (1..<40).map { "<td>c\($0)</td>" }.joined() + "<td style='border-right:5px solid red'>c40</td>"
        let table = "<table><tr>\(cells)</tr><tr>\(cells)</tr></table>\n"
        let control = try await Raster(printPage(lead, theme: decorated))
        let page = try await printPage(lead + table, theme: decorated)
        let actual = try Raster(page)
        let body = try control.bounds(channel: 2)
        #expect(actual.rows(through: body.maxY + 4) == control.rows(through: body.maxY + 4))
        checkOutsideRule(try actual.bounds(channel: 0), pageWidth: page.bounds(for: .mediaBox).width)
    }
}
