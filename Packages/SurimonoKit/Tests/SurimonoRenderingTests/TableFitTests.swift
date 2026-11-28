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
        theme chosen: PrintTheme? = nil, footnotes: FootnotePlacement = .end, textScale: Double = 1,
        format: DocumentFormat = .markdown,
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
        settings.textScale = textScale
        return try await renderer.render(DocumentSource(data: Data(body.utf8), format: format), settings: settings)
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

    /// The device pixel ratio a print was laid out at.
    @MainActor
    private final class PixelRatio {
        var value: Double?
        func record(_ view: WKWebView) async {
            value =
                try? await view.evaluateForPrinting("return devicePixelRatio", until: .now + .seconds(10)) as? Double
        }
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

    /// How the first table of the printed DOM was laid out: the most lines a cell of each column takes, the least
    /// text width a cell of each column has in its own ems, how many pieces of text or boxes in it lie outside their
    /// cell's left or right edge, its zoom, and whether it counts as fitted. A table that could not be observed
    /// records an issue, so that empty columns do not pass for kept ones.
    @MainActor
    private final class Columns {
        var lines: [Int] = []
        var ems: [Double] = []
        var outside = -1
        var zoom = 1.0
        var fitted = false
        var log = ""
        func record(_ view: WKWebView) async {
            let json = try? await view.evaluateForPrinting(
                """
                const table = document.querySelector('table');
                const px = value => parseFloat(value) || 0;
                const rectsIn = cell => {
                    const rects = [];
                    const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
                    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                        if (!node.data.trim()) continue;
                        const range = document.createRange();
                        range.selectNodeContents(node);
                        for (const rect of range.getClientRects()) if (rect.width && rect.height) rects.push(rect);
                    }
                    return rects;
                };
                const lines = cell => {
                    const rects = rectsIn(cell).sort((a, b) => a.top - b.top);
                    let count = 0, bottom = -Infinity;
                    for (const rect of rects) {
                        if (rect.top >= bottom - 1) { count++; bottom = rect.bottom; }
                        else bottom = Math.max(bottom, rect.bottom);
                    }
                    return count;
                };
                const ems = cell => {
                    const css = getComputedStyle(cell);
                    const text = cell.clientWidth - px(css.paddingLeft) - px(css.paddingRight);
                    return text / px(css.fontSize);
                };
                let outside = 0;
                for (const cell of table.querySelectorAll('td, th')) {
                    const box = cell.getBoundingClientRect();
                    const pieces = [...rectsIn(cell), ...[...cell.querySelectorAll('*')].map(el => el.getBoundingClientRect())];
                    outside += pieces.filter(r => r.width && (r.left < box.left - 1 || r.right > box.right + 1)).length;
                }
                const rows = [...table.rows];
                const count = rows.reduce((most, row) => Math.max(most, row.cells.length), 0);
                const columns = [], widths = [];
                for (let i = 0; i < count; i++) {
                    const cells = rows.map(row => row.cells[i]).filter(Boolean);
                    columns.push(cells.reduce((most, cell) => Math.max(most, lines(cell)), 0));
                    widths.push(cells.reduce((least, cell) => Math.min(least, ems(cell)), Infinity));
                }
                return JSON.stringify({ lines: columns, ems: widths, outside,
                    zoom: parseFloat(getComputedStyle(table).zoom) || 1,
                    fitted: globalThis.surimonoFittedTables?.has(table) === true,
                    log: globalThis.surimonoTableFitLog ?? null });
                """, until: .now + .seconds(10))
            guard let text = json as? String,
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let lines = object["lines"] as? [Int], let ems = object["ems"] as? [Double],
                let outside = object["outside"] as? Int
            else {
                Issue.record("The printed table could not be observed")
                return
            }
            self.lines = lines
            self.ems = ems
            self.outside = outside
            zoom = object["zoom"] as? Double ?? 1
            fitted = object["fitted"] as? Bool ?? false
            log = text + " on " + ProcessInfo.processInfo.operatingSystemVersionString
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

    @Test("40列表だけを縮めて最後の列を刷り、どの列の見出しと数も割らず、外罫と本文の右端の間に余裕を残す", .timeLimit(.minutes(1)))
    func fortyColumns() async throws {
        let lead = "# Comparison\n\n<span style='color:blue'>H</span>\n\n"
        let control = try await Raster(printPage(lead))
        let columns = Columns()
        let document = try await printed(lead + wideTable(rows: 1), inspect: columns.record).logicalDocument
        try #require(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        // "c10" and "10" each on one line, not "c1" over "0". The first column holds the row markers, boxes that
        // are not text.
        try #require(columns.lines.count == 40, Comment(rawValue: columns.log))
        #expect(columns.lines.dropFirst().allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        // Narrowed sideways, the header is still text: found once, as it was written.
        #expect(document.findString("c37", withOptions: []).count == 1)
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
        let controlRatio = PixelRatio()
        let actualRatio = PixelRatio()
        let (control, result) = try await atDeviceScale(CGFloat(scale)) {
            (
                try await Raster(
                    #require(printed(lead, css: css, inspect: controlRatio.record).logicalDocument.page(at: 0))),
                try await printed(
                    lead + table, css: css,
                    inspect: { view in
                        await actualRatio.record(view)
                        await log.record(view)
                        await fitted.record(view)
                    })
            )
        }
        // Both prints were laid out at the scale asked for.
        #expect(controlRatio.value == scale && actualRatio.value == scale)
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

    @Test("表の中の数式は、折り返さない指定を外すときも描いたまま刷る", .timeLimit(.minutes(1)))
    func formulasKeepTheirLines() async throws {
        // Only the nowrap cell makes the table too wide, so it is wrapped, not zoomed; the formula is drawn
        // in the same place either way.
        let table =
            "| text | formula |\n|---|---|\n| " + String(repeating: "長いセル。", count: 30)
            + " | $x^2 + \\frac{1}{2}$ |\n"
        let css = "table { width: 90% !important; box-sizing: border-box } .math { color: lime }"
        let reference = try await Raster(printPage(paragraph + table, fit: false, css: css))
        let fitted = try await Raster(
            printPage(paragraph + table, css: css + " td:first-child { white-space: nowrap }"))
        let formula = try reference.bounds(channel: 1)
        #expect(try fitted.bounds(channel: 1) == formula)
        #expect(fitted.pixels(in: formula) == reference.pixels(in: formula))
    }

    @Test(
        "本文の幅と内側の余白に端数があっても、収まる幅いっぱいの表は変えない", .timeLimit(.minutes(1)),
        arguments: [531.25, 637.4])
    func fractionalFit(width: Double) async throws {
        _ = NSApplication.shared
        let base = try theme
        let padded = PrintTheme(id: base.id, name: base.name, css: base.css + "\nbody { padding: 0 10.3px }")
        // In a column 531.25 pixels wide the body is 531.25 - 20.6 = 510.65; rounded to whole pixels, the table
        // (511) would look wider than the body measured from its own rounded width (531 - 20.6 = 510.4).
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<table style='width:100%'><tr><td>a</td><td>b</td></tr></table>"),
            format: .markdown, theme: padded)
        let source = WebPaginator.Source.html(html, baseURL: nil)
        let session = PaginationSession(
            source: source, pageSize: PrintLayout.a4Single.logicalPageSize, margins: .uniform(millimeters: 15),
            allowsJavaScript: false, printsBackgrounds: true, printTimeout: .seconds(10),
            onPrintStart: { _ in }, onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        _ = try await session.loadForPrinting(source, timeout: .seconds(10), expireAfterCommit: nil)
        session.webView.mediaType = "print"
        let changed = try await TableFit.fit(
            in: session.webView, width: CGFloat(width), until: .now + .seconds(10))
        #expect(!changed)
        let style = try await session.webView.evaluateForPrinting(
            "return document.querySelector('table').getAttribute('style')", until: .now + .seconds(10))
        #expect(style as? String == "width:100%")
    }

    @Test("文字が最小の大きさで止まる表は、等倍へ戻さず効いた所まで縮めてから横を詰める", .timeLimit(.minutes(1)))
    func zoomKeptAtTextFloor() async throws {
        // Single glyphs in bare cells: the text, which stops at WebKit's minimum size, is most of the width.
        let cells = (1...130).map { _ in "<td style='padding:0'>8</td>" }.joined()
        let log = FitLog()
        _ = try await printed(
            "<table style='font-size:12px'><tr>\(cells)</tr></table>\n", layout: .a4TwoUp, inspect: log.record)
        let data = try #require(log.text.split(separator: " on ").first.map { Data($0.utf8) })
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let step = try #require((record["steps"] as? [[String: Any]])?.first)
        let scale = try #require(step["scale"] as? Double)
        let narrowing = try #require(step["narrowing"] as? Double)
        // The table is zoomed as far as its text shrinks, and narrowed alone for the rest only. Throwing the
        // zoom away narrows to about 0.35; keeping it gives 0.45 at 1x and 0.49 at 2x, where glyphs round differently.
        #expect(scale < 0.9, Comment(rawValue: log.text))
        #expect(narrowing > 0.4, Comment(rawValue: log.text))
    }

    @Test("内側の余白と外罫を幅に含めない指定の表も、本文の幅の中に刷る", .timeLimit(.minutes(1)))
    func contentBoxTable() async throws {
        let css = "table { box-sizing: content-box !important; padding: 0 6px; border-left: 3px solid gray !important }"
        let fitted = Fitted()
        let result = try await printed(wideTable(rows: 1), css: css, inspect: fitted.record)
        #expect(fitted.value)
        #expect(result.issues.isEmpty)
        let page = try #require(result.logicalDocument.page(at: 0))
        checkOutsideRule(try Raster(page).bounds(channel: 0), pageWidth: page.bounds(for: .mediaBox).width)
    }

    @Test("語の途中で折り返さないスタイルでは、折り返さない指定を外すだけで収まる表の語を割らない", .timeLimit(.minutes(1)))
    func wordsKeptWhole() async throws {
        let table =
            "<table style='width:90%;box-sizing:border-box'><tr><td>Status</td><td style='white-space:nowrap'>"
            + String(repeating: "A long cell that should wrap between words. ", count: 12) + "</td></tr></table>"
        let css = "td { overflow-wrap: normal }"
        let reference = try await Raster(
            printPage(paragraph + table.replacingOccurrences(of: "nowrap", with: "normal"), fit: false, css: css))
        let fitted = try await Raster(printPage(paragraph + table, css: css))
        #expect(fitted.data == reference.data)
    }

    @Test("文字の大きさが50%でも200%でも、右の外罫と本文の右端のすき間は紙の上で同じ", .timeLimit(.minutes(1)), arguments: [0.5, 2.0])
    func reserveOnPaper(textScale: Double) async throws {
        let result = try await printed(wideTable(rows: 1), textScale: textScale)
        let page = try #require(result.logicalDocument.page(at: 0))
        let rule = try Raster(page).bounds(channel: 0)
        checkOutsideRule(rule, pageWidth: page.bounds(for: .mediaBox).width)
        // The reserve is a length on paper: the same gap, between 1 and 2 points, at every text scale.
        let gap = ((page.bounds(for: .mediaBox).width - 15 * 72 / 25.4) * 2 - rule.maxX) / 2
        #expect(gap >= 1 && gap <= 2, "gap \(gap) pt")
    }

    @Test("横に並べる入れ物の中の表は測れないので、今までどおりにする", .timeLimit(.minutes(1)))
    func flexContainerLeftAlone() async throws {
        let cells = (1...40).map { "<td>c\($0)</td>" }.joined()
        let source =
            "<div style='display:flex;gap:12px'><span>!</span><div><table><tr>\(cells)</tr></table></div></div>\n"
        let original = try await Raster(
            #require(printed(source, fit: false).logicalDocument.page(at: 0)))
        let fitted = try await Raster(#require(printed(source).logicalDocument.page(at: 0)))
        #expect(original.data == fitted.data)
    }

    private static let longURL =
        "https://example.com/a/very/long/url/that/keeps/going/and/going/without/any/space/in/it/at/all/index.html"
        + "?query=1&another=2&more=3"

    @Test("短い列は1行にしたときの幅が表の幅の3割以下の列")
    func shortColumnShare() throws {
        let js = try #require(JSContext())
        js.evaluateScript(TableFit.planFunctions)
        let isShort = try #require(js.objectForKeyedSubscript("isShortColumn"))
        #expect(isShort.call(withArguments: [191.25, 637.5]).toBool())
        #expect(!isShort.call(withArguments: [191.5, 637.5]).toBool())
        #expect(js.exception == nil)
    }

    private struct Plan: Equatable {
        let scale: Double
        let narrowing: Double
    }

    private static func short(_ width: Double) -> [String: Any] { ["short": true, "width": width, "padding": 14] }
    private static func long(_ width: Double, padding: Double = 14) -> [String: Any] {
        ["short": false, "width": width, "padding": padding, "text": width - padding]
    }

    /// The whole plan for a table with this room, 14-pixel type laid out at `text` pixels, and these columns.
    private func fullPlan(room: Double, text: Double = 14, _ columns: [[String: Any]]) throws -> JSValue {
        let js = try #require(JSContext())
        js.evaluateScript(TableFit.planFunctions)
        let function = try #require(js.objectForKeyedSubscript("tablePlan"))
        let result = try #require(function.call(withArguments: [room, 14, text, columns]))
        #expect(js.exception == nil)
        return result
    }

    /// The zoom and narrowing of the plan.
    private func plan(room: Double, text: Double = 14, _ columns: [[String: Any]]) throws -> Plan {
        let result = try fullPlan(room: room, text: text, columns)
        return Plan(
            scale: result.objectForKeyedSubscript("scale").toDouble(),
            narrowing: result.objectForKeyedSubscript("narrowing").toDouble())
    }

    @Test("長い列ごとに、文字の幅と4文字ぶんの小さい方を下限として返し、余白は列ごとに数える")
    func planFloorsEachLongColumn() throws {
        let result = try fullPlan(
            room: 600, [Self.short(100), Self.long(400), Self.long(40), Self.long(300, padding: 30)])
        let floors = try #require(result.objectForKeyedSubscript("floors").toArray() as? [Double])
        #expect(floors == [0, 56, 26, 56])
        // 100 + (14 + 56) + (14 + 26) + (30 + 56), more than 30% of the room.
        #expect(result.objectForKeyedSubscript("need").toDouble() == 296)
    }

    @Test("短い列を守ると横に半分より詰めることになる表は、短い列を守らない")
    func planGivesUpShortColumnsBelowHalfWidth() throws {
        // 1500 in 600 at 9 of 14 pixels: narrowed to 0.62. 3000: 0.31.
        let kept = try fullPlan(room: 600, Array(repeating: Self.short(50), count: 30))
        let given = try fullPlan(room: 600, Array(repeating: Self.short(50), count: 60))
        #expect(kept.objectForKeyedSubscript("keepsShort").toBool())
        #expect(!given.objectForKeyedSubscript("keepsShort").toBool())
    }

    @Test("守らない短い列は、表の縮め方に数えない")
    func planIgnoresFreeColumns() throws {
        let free: [String: Any] = ["short": false, "free": true, "width": 50, "padding": 14, "text": 36]
        #expect(
            try plan(room: 600, Array(repeating: free, count: 60) + [Self.long(400)]) == Plan(scale: 1, narrowing: 1))
    }

    @Test("短い列の1行の幅と長い列の下限が本文の幅に入る表は、縮めない")
    func planAtFullSize() throws {
        // The long column keeps 30% of 600, less than the 400 it has: 100 + 120 + 180 = 400.
        let columns = [Self.short(100), Self.short(120), Self.long(400)]
        #expect(try plan(room: 600, columns) == Plan(scale: 1, narrowing: 1))
    }

    @Test("入らない表は、短い列を1行のまま、長い列に下限が残る倍率まで表ごと縮める")
    func planZoomsTheTable() throws {
        // 300 + 300 + 180 = 780 at full size, in 600.
        #expect(
            try plan(room: 600, [Self.short(300), Self.short(300), Self.long(400)])
                == Plan(scale: 600.0 / 780, narrowing: 1))
    }

    @Test("縮める倍率は列の数によらず、短い列の幅の合計と長い列の下限だけで決まる")
    func planIgnoresColumnCount() throws {
        let one = try plan(room: 600, [Self.short(600), Self.long(400)])
        let four = try plan(room: 600, Array(repeating: Self.short(150), count: 4) + [Self.long(400)])
        let forty = try plan(room: 600, Array(repeating: Self.short(15), count: 40) + [Self.long(400)])
        // Two long columns of 200 keep 30% of the room together, as one of 400 does.
        let twoLong = try plan(room: 600, [Self.short(600), Self.long(200), Self.long(200)])
        #expect(one == Plan(scale: 600.0 / 780, narrowing: 1))
        #expect(four == one)
        #expect(forty == one)
        #expect(twoLong == one)
    }

    @Test("長い列は合わせて表の幅の3割か各4文字ぶんの大きい方を、もとの幅までは残す")
    func planLongColumnFloor() throws {
        // A long column that had less keeps what it had: 500 + 100 = 600 fits.
        #expect(try plan(room: 600, [Self.short(500), Self.long(100)]) == Plan(scale: 1, narrowing: 1))
        // Five long columns keep 14 + 4 × 14 each, 350 together, more than 30%: 400 + 350 = 750.
        #expect(
            try plan(room: 600, [Self.short(400)] + Array(repeating: Self.long(300), count: 5))
                == Plan(scale: 600.0 / 750, narrowing: 1))
    }

    @Test("文字が9ピクセルになる倍率より先は縮めず、残りは横に詰める")
    func planStopsAtTheSmallestType() throws {
        // 1500 in 600 would be 0.4; the type stops at 9 of 14 pixels, and the rest is narrowed.
        let least = 9.0 / 14
        #expect(
            try plan(room: 600, Array(repeating: Self.short(50), count: 30))
                == Plan(scale: least, narrowing: 600 / (1500 * least)))
        // Type already smaller than that is not zoomed at all.
        #expect(
            try plan(room: 600, text: 7, Array(repeating: Self.short(50), count: 30))
                == Plan(scale: 1, narrowing: 0.4))
    }

    @Test(
        "長いURLの隣の短い列は、日本語も14文字の英語も本文と同じ1行で刷る", .timeLimit(.minutes(1)),
        arguments: [("項目名", 1.0), ("項目名", 2.0), ("Not applicable", 1.0), ("Not applicable", 2.0)])
    func labelsKeptWhole(label: String, scale: Double) async throws {
        let mark = "<span style='color:lime'>\(label)</span>"
        let table = "| \(label) | 値 |\n|---|---|\n| \(mark) | \(Self.longURL) |\n"
        let (control, actual) = try await atDeviceScale(CGFloat(scale)) {
            (try await Raster(printPage(mark + "\n")), try await Raster(printPage(table)))
        }
        // The label in the table is drawn as in a paragraph: the same glyphs on one line, not one per line. A
        // pixel of width comes and goes with where the glyphs fall between pixels.
        let expected = try control.bounds(channel: 1)
        let cell = try actual.bounds(channel: 1)
        #expect(cell.height == expected.height, "label \(cell), in a paragraph \(expected)")
        #expect(abs(cell.width - expected.width) <= 1, "label \(cell), in a paragraph \(expected)")
    }

    /// The page as printed, and as printed without TableFit.
    private func withAndWithout(_ source: String) async throws -> (fitted: Raster, original: Raster) {
        let fitted = try await printed(source)
        let original = try await printed(source, fit: false)
        return (
            try Raster(#require(fitted.logicalDocument.page(at: 0))),
            try Raster(#require(original.logicalDocument.page(at: 0)))
        )
    }

    @Test("表の幅の3割より長い語の列は、隣に長いURLがあっても今までどおりにする", .timeLimit(.minutes(1)))
    func longWordColumnLeftAlone() async throws {
        // Japanese, so it is squeezed to a character a line like a short label, but wider than 30% on one line.
        let word = "とても長い項目の名前がここに続きます"
        let pages = try await withAndWithout("| 名前 | 値 |\n|---|---|\n| \(word) | \(Self.longURL) |\n")
        #expect(pages.fitted.data == pages.original.data)
    }

    @Test("短い列を全部1行にすると長い列が下限より狭くなる表は、どの短い列も割らずに表を縮める", .timeLimit(.minutes(1)))
    func longColumnFloorKept() async throws {
        // All four kept whole would still fit, but leave the URL less than 30% of the room.
        let source =
            "| a | b | c | d | 値 |\n|---|---|---|---|---|\n"
            + "| Not applicable for now | Not applicable for now | Not applicable | Not applicable | \(Self.longURL) |\n"
        let columns = Columns()
        let result = try await printed(source, inspect: columns.record)
        try #require(columns.lines.count == 5, Comment(rawValue: columns.log))
        #expect(columns.lines.prefix(4).allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        #expect(columns.zoom < 1, Comment(rawValue: columns.log))
        #expect(columns.fitted)
        #expect(result.issues.isEmpty)
    }

    @Test("Word の表のように段落に入ったセルでも、長いセルの隣の短い列は1行で刷る", .timeLimit(.minutes(1)))
    func paragraphCellsKeptWhole() async throws {
        func row(_ cells: [String]) -> String { "<tr>" + cells.map { "<td><p>\($0)</p></td>" }.joined() + "</tr>" }
        let note = "内側の線は製作時の目印で、割れではないことを記録票と照合した。"
        let source =
            "<table><thead><tr>" + ["番号", "高さ", "状態", "備考"].map { "<th><p>\($0)</p></th>" }.joined()
            + "</tr></thead><tbody>" + row(["A-001", "181 mm", "確認済み", note]) + row(["A-002", "182 mm", "要再確認", note])
            + "</tbody></table>\n"
        let columns = Columns()
        _ = try await printed(source, inspect: columns.record)
        try #require(columns.lines.count == 4, Comment(rawValue: columns.log))
        #expect(columns.lines.prefix(3).allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        // There is room for them at full size.
        #expect(columns.zoom == 1, Comment(rawValue: columns.log))
    }

    @Test("幅を決めた段落の短い列は、1行にすると文字がセルの外へ出るので守らず、文字をセルの中に刷る", .timeLimit(.minutes(1)))
    func boxedParagraphNotKept() async throws {
        let source =
            "<table><tr><td><p style='width:20px;direction:rtl'>Status Confirmed</p></td><td>"
            + String(repeating: "X", count: 500) + "</td></tr></table>\n"
        let columns = Columns()
        _ = try await printed(source, inspect: columns.record)
        try #require(columns.lines.count == 2, Comment(rawValue: columns.log))
        #expect(columns.outside == 0, Comment(rawValue: columns.log))
    }

    @Test("短い4列と長い2列の表は、長い列のどちらにも4文字ぶんの文字の幅を残す", .timeLimit(.minutes(1)))
    func eachLongColumnKeepsItsFloor() async throws {
        let cells =
            Array(repeating: "short label", count: 4)
            + [String(repeating: "X", count: 60), String(repeating: "X", count: 250)]
        let source = "<table><tr>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr></table>\n"
        let columns = Columns()
        _ = try await printed(source, inspect: columns.record)
        try #require(columns.lines.count == 6, Comment(rawValue: columns.log))
        #expect(columns.lines.prefix(4).allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        // A pixel of rounding either way.
        #expect(columns.ems.suffix(2).allSatisfy { $0 >= 3.9 }, Comment(rawValue: columns.log))
    }

    @Test("1行のままでは横に半分より詰めることになる日付50列の表は、ハイフンの後でだけ折り返し、数字の途中で割らない", .timeLimit(.minutes(1)))
    func datesWrapAtHyphensWhenTooNarrow() async throws {
        let row = "<tr>" + String(repeating: "<td>2026-11-29</td>", count: 50) + "</tr>"
        let columns = Columns()
        let result = try await printed("<table>\(row)\(row)</table>\n", inspect: columns.record)
        try #require(columns.lines.count == 50, Comment(rawValue: columns.log))
        // "2026-", "11-", "29": three lines at most, never "20" over "26".
        #expect(columns.lines.allSatisfy { $0 >= 1 && $0 <= 3 }, Comment(rawValue: columns.log))
        #expect(columns.lines.contains { $0 > 1 }, Comment(rawValue: columns.log))
        #expect(columns.outside == 0, Comment(rawValue: columns.log))
        #expect(result.issues.isEmpty)
    }

    @Test("短い列だけで本文の幅を超えるCSVの表は、どの列も割らずに表を縮めて本文の幅に収める", .timeLimit(.minutes(1)))
    func manyShortColumnsZoomed() async throws {
        let head = (1...16).map { "項目\($0)" }
        let row = (1...15).map { "K-\(String(format: "%03d", $0))" } + ["記録を照合する"]
        let source = ([head] + Array(repeating: row, count: 3))
            .map { $0.joined(separator: ",") }.joined(separator: "\n")
        let columns = Columns()
        let result = try await printed(source + "\n", format: .csv, inspect: columns.record)
        try #require(columns.lines.count == 16, Comment(rawValue: columns.log))
        #expect(columns.lines.dropLast().allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        #expect(columns.zoom < 1, Comment(rawValue: columns.log))
        #expect(columns.fitted)
        #expect(result.issues.isEmpty)
    }

    @Test("改行を保つ指定で改行のあるセルがある列は、短くても今までどおりにする", .timeLimit(.minutes(1)))
    func keptLineBreaksLeftAlone() async throws {
        let source =
            "<table><tr><th>名前</th><th>値</th></tr><tr><td style='white-space:pre-wrap'>A\nB</td>"
            + "<td>\(Self.longURL)</td></tr></table>\n"
        let pages = try await withAndWithout(source)
        #expect(pages.fitted.data == pages.original.data)
    }

    @Test("空白を保つ指定のセルの短い列は、空白をそのままに1行で刷る", .timeLimit(.minutes(1)))
    func keptSpacesOnOneLine() async throws {
        let mark = "<span style='color:lime'>A    B</span>"
        let source =
            "<table><tr><th>名前</th><th>値</th></tr><tr><td style='white-space:pre-wrap'>\(mark)</td>"
            + "<td>\(Self.longURL)</td></tr></table>\n"
        // Four spaces kept, as pre draws them in a paragraph; collapsed to one, the label would be narrower.
        let control = try await Raster(printPage("<p style='white-space:pre'>\(mark)</p>\n"))
        let actual = try await Raster(printPage(source))
        let expected = try control.bounds(channel: 1)
        let cell = try actual.bounds(channel: 1)
        #expect(cell.height == expected.height, "label \(cell), in a paragraph \(expected)")
        #expect(abs(cell.width - expected.width) <= 1, "label \(cell), in a paragraph \(expected)")
    }

    @Test("CSVの表でも、長いセルの隣の短い列は1行で刷る", .timeLimit(.minutes(1)))
    func csvLabelsKeptWhole() async throws {
        let css = ".surimono-csv td:first-child { color: lime }"
        let control = try await Raster(printPage("<span style='color:lime'>項目名</span>\n"))
        let result = try await printed(
            "名前,値\n項目名,\(Self.longURL)\n", css: css, format: .csv)
        let actual = try Raster(#require(result.logicalDocument.page(at: 0)))
        let expected = try control.bounds(channel: 1)
        let cell = try actual.bounds(channel: 1)
        #expect(cell.height == expected.height, "label \(cell), in a paragraph \(expected)")
        #expect(abs(cell.width - expected.width) <= 1, "label \(cell), in a paragraph \(expected)")
    }

    @Test("行の残りをまたぐセルのある表は、列の並びが単純でないので今までどおりにする", .timeLimit(.minutes(1)))
    func spanningRowsLeftAlone() async throws {
        let source =
            "<table><tr><td rowspan='0'>項目名</td><td>\(Self.longURL)</td></tr>"
            + "<tr><td>担当者</td></tr></table>\n"
        let pages = try await withAndWithout(source)
        #expect(pages.fitted.data == pages.original.data)
    }

    @Test("短い列を守った表は収まった表として扱って警告せず、何もしなかった表は扱わない", .timeLimit(.minutes(1)))
    func keptTablesRegistered() async throws {
        let kept = Fitted()
        let result = try await printed(
            "| 項目名 | 値 |\n|---|---|\n| 項目名 | \(Self.longURL) |\n", inspect: kept.record)
        #expect(kept.value)
        #expect(result.issues.isEmpty)
        let untouched = Fitted()
        _ = try await printed("| 名前 | URL |\n|---|---|\n| one | two |\n", inspect: untouched.record)
        #expect(!untouched.value)
    }

    @Test("折り返さない指定で広い表でも、強調の中の短い語の列は1行で刷る", .timeLimit(.minutes(1)))
    func labelsKeptInWideTable() async throws {
        let mark = "<em style='color:lime'>Status</em>"
        let source =
            "<table style='white-space:nowrap'><tr><td>\(mark)</td><td>"
            + String(repeating: "折り返さない指定の長いセルの中身です。", count: 6) + "</td></tr></table>\n"
        let control = try await Raster(printPage(mark + "\n"))
        let actual = try await Raster(printPage(source))
        let expected = try control.bounds(channel: 1)
        let cell = try actual.bounds(channel: 1)
        #expect(cell.height == expected.height, "label \(cell), in a paragraph \(expected)")
        #expect(abs(cell.width - expected.width) <= 1, "label \(cell), in a paragraph \(expected)")
    }

    @Test(
        "短い語の隣の長いURLは、末尾まで本文の幅の中で折り返し、右の外罫を太さそのままに刷る", .timeLimit(.minutes(1)),
        arguments: [(1.0, 1.0), (1.0, 2.0), (1.2, 1.0), (1.2, 2.0)])
    func longCellWrapsBesideLabels(textScale: Double, scale: Double) async throws {
        // The last characters of the URL are blue, so a cut end shows.
        let url = Self.longURL.dropLast(7) + "<span style='color:blue'>" + Self.longURL.suffix(7) + "</span>"
        let table = "| 項目名 | 値 |\n|---|---|\n| 名前 | \(url) |\n"
        let (result, narrow) = try await atDeviceScale(CGFloat(scale)) {
            (
                try await printed(table, textScale: textScale),
                try await printed("| a | b |\n|---|---|\n| 1 | 2 |\n", textScale: textScale)
            )
        }
        let page = try #require(result.logicalDocument.page(at: 0))
        let pixels = try Raster(page)
        let end = try pixels.bounds(channel: 2)
        let border = try pixels.bounds(channel: 0)
        #expect(end.width > 20 && end.maxX < border.minX)
        // The right rule of a narrow table, wholly inside the page, is as thick as this one: on a screen that is
        // not Retina, where the rule falls between pixels moves a pixel of it, but a rule cut in half or gone
        // would be far thinner.
        let whole = try Raster(#require(narrow.logicalDocument.page(at: 0))).bounds(channel: 0)
        #expect(abs(border.width - whole.width) <= 1, "rule \(border), whole \(whole)")
        let rightEdge = (page.bounds(for: .mediaBox).width - 15 * 72 / 25.4) * 2
        #expect(border.maxX <= ceil(rightEdge))
    }

    @Test(
        "空白で区切った語の列は、1行にして表の幅の3割をわずかに超えるなら守らない", .timeLimit(.minutes(1)),
        arguments: [
            // About 194 and 195 pixels on one line, padding and rules included; 30% of the room is 191.25.
            Array(repeating: "A", count: 12).joined(separator: " "),
            Array(repeating: "<b>AB</b>", count: 7).joined(separator: " "),
        ])
    func spacedWordsJustTooWide(words: String) async throws {
        let pages = try await withAndWithout("| X | 値 |\n|---|---|\n| \(words) | \(Self.longURL) |\n")
        #expect(pages.fitted.data == pages.original.data)
    }

    @Test("空白で区切った語の列は、1行にして表の幅の3割をわずかに下回るなら1行で刷る", .timeLimit(.minutes(1)))
    func spacedWordsJustShort() async throws {
        // About 179 pixels on one line.
        let mark = "<span style='color:lime'>" + Array(repeating: "A", count: 11).joined(separator: " ") + "</span>"
        let control = try await Raster(printPage(mark + "\n"))
        let actual = try await Raster(printPage("| X | 値 |\n|---|---|\n| \(mark) | \(Self.longURL) |\n"))
        let expected = try control.bounds(channel: 1)
        let cell = try actual.bounds(channel: 1)
        #expect(cell.height == expected.height, "label \(cell), in a paragraph \(expected)")
        #expect(abs(cell.width - expected.width) <= 1, "label \(cell), in a paragraph \(expected)")
    }

    /// The style attribute of the first element marked data-kept, as the print saw it.
    @MainActor
    private final class KeptStyle {
        var value: String?
        func record(_ view: WKWebView) async {
            value =
                try? await view.evaluateForPrinting(
                    "return document.querySelector('[data-kept]')?.getAttribute('style') ?? 'none'",
                    until: .now + .seconds(10)) as? String
        }
    }

    @Test(
        "1行にすると表の幅の3割を超えて守るのをやめた列では、空白の扱いだけを書いたセルのスタイルを残し、折り返さない指定を戻す",
        .timeLimit(.minutes(1)))
    func styleRestoredWhole() async throws {
        // The words of spacedWordsJustTooWide: estimated short, measured on one line just too wide.
        let words = Array(repeating: "A", count: 12).joined(separator: " ")
        let source =
            "<table><tr><th>X</th><th>値</th></tr><tr><td data-kept style='white-space-collapse: collapse'>"
            + "\(words)</td><td>\(Self.longURL)</td></tr></table>\n"
        let style = KeptStyle()
        _ = try await printed(source, inspect: style.record)
        // As a long column it may get its floor (a min-width) after the author's own style.
        let value = try #require(style.value)
        #expect(value.hasPrefix("white-space-collapse: collapse"), "\(value)")
        #expect(!value.contains("white-space:"), "\(value)")
    }

    @Test("長い列の余白が大きく、その文字の幅が下限より狭くなる表は、短い列を割らずに表を縮める", .timeLimit(.minutes(1)))
    func longColumnContentFloor() async throws {
        // With its padding the URL's column keeps more than 30% of the room, its text 4 ems.
        let labels = Array(repeating: "Not applicable", count: 3)
        let source =
            "| " + labels.joined(separator: " | ") + " | 値 |\n|" + String(repeating: "---|", count: 4) + "\n| "
            + labels.joined(separator: " | ") + " | \(Self.longURL) |\n"
        let css = "th, td { box-sizing: border-box } th:last-child, td:last-child { padding: 0 140px }"
        let columns = Columns()
        _ = try await printed(source, css: css, inspect: columns.record)
        try #require(columns.lines.count == 4, Comment(rawValue: columns.log))
        #expect(columns.lines.prefix(3).allSatisfy { $0 == 1 }, Comment(rawValue: columns.log))
        #expect(columns.zoom < 1, Comment(rawValue: columns.log))
        #expect(columns.fitted)
    }

    @Test("表示しない列があっても、表の縮め方は見えている列だけで決める", .timeLimit(.minutes(1)))
    func hiddenColumnDoesNotCount() async throws {
        // The table of longColumnContentFloor, with and without a column that is not displayed and holds a block.
        func table(hidden: Bool) -> String {
            let label = "<td>Not applicable</td>"
            let head = hidden ? "<th style=\"display:none\"><p>hidden</p></th>" : ""
            let cell = hidden ? "<td style=\"display:none\"><p>hidden</p></td>" : ""
            return """
                <table>
                <thead><tr><th>Not applicable</th><th>Not applicable</th><th>Not applicable</th><th class="wide">値</th>\
                \(head)</tr></thead>
                <tbody><tr>\(label)\(label)\(label)<td class="wide">\(Self.longURL)</td>\(cell)</tr></tbody>
                </table>

                """
        }
        let css = "th, td { box-sizing: border-box } .wide { padding: 0 140px }"
        let with = Columns()
        let without = Columns()
        _ = try await printed(table(hidden: true), css: css, inspect: with.record)
        _ = try await printed(table(hidden: false), css: css, inspect: without.record)
        try #require(with.lines.count == 5 && without.lines.count == 4, Comment(rawValue: with.log + without.log))
        #expect(with.lines.prefix(3).allSatisfy { $0 == 1 }, Comment(rawValue: with.log))
        // WebKit lays the two tables out a few pixels apart even untouched, so the zooms are close, not equal.
        #expect(with.zoom < 1 && abs(with.zoom - without.zoom) < 0.01, Comment(rawValue: with.log + without.log))
        #expect(with.fitted)
    }

    /// The rows of pixels that hold lime, as runs of rows with lime in them, top to bottom.
    private func limeRuns(_ raster: Raster) -> [ClosedRange<Int>] {
        let height = raster.data.count / 4 / raster.width
        var runs: [ClosedRange<Int>] = []
        raster.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let row = (0..<raster.width).contains { x in
                    let i = (y * raster.width + x) * 4
                    return bytes[i + 1] > 160 && bytes[i] < 80 && bytes[i + 2] < 80
                }
                guard row else { continue }
                if let last = runs.last, last.upperBound == y - 1 {
                    runs[runs.count - 1] = last.lowerBound...y
                } else {
                    runs.append(y...y)
                }
            }
        }
        return runs
    }

    @Test(
        "短い6列と長い2列の表は、短い列を1行のまま本文の幅に収め、本文の大きさを変えない", .timeLimit(.minutes(1)),
        arguments: [1.0, 2.0])
    func manyLabelsBesideTwoLongColumns(scale: Double) async throws {
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }
        let long = "見開きの面付けを目視で確かめ、余白と折り目の位置に問題がないことを確かめました。"
        let note = "予備を含む。次回は別の判でも同じ原稿を試す予定。"
        let table =
            row(["No", "日付", "区分", "状態", "金額", "担当者", "説明", "備考"])
            + row(["---:", "---", "---", "---", "---:", "---", "---", "---"])
            + row(["1", "2026-11-01", "印刷", "完了", "12,800", "担当甲", long, note])
            + row(["2", "2026-11-12", "組版", "確認中", "4,500", "担当乙", long, note])
            + row(["100", "2026-11-28", "配布", "未着手", "128,000", "担当丙", long, note])
        // Every cell of the six short columns is lime, so a cell that wraps adds a line of lime below the rest.
        let css = ":is(th, td):nth-child(-n+6) { color: lime }"
        let (control, result, line) = try await atDeviceScale(CGFloat(scale)) {
            (
                try await Raster(printPage(paragraph)), try await printed(paragraph + table, css: css),
                try await Raster(printPage("<span style='color:lime'>2026-11-28 128,000 未着手</span>\n"))
            )
        }
        let page = try #require(result.logicalDocument.page(at: 0))
        let actual = try Raster(page)
        // The text above the table is the same pixels as without it: the page was not shrunk.
        let body = try control.bounds(channel: 2)
        #expect(actual.rows(through: body.maxY + 4) == control.rows(through: body.maxY + 4))
        // One line of lime a row, the header's and the three of the body, each as tall as a line of them.
        let oneLine = try line.bounds(channel: 1).height
        let runs = limeRuns(actual)
        #expect(runs.count == 4, "\(runs)")
        #expect(runs.allSatisfy { $0.count <= Int(oneLine) + 1 }, "\(runs), a line \(oneLine)")
        // The right rule is inside the text column.
        let border = try actual.bounds(channel: 0)
        let rightEdge = (page.bounds(for: .mediaBox).width - 15 * 72 / 25.4) * 2
        #expect(border.maxX <= ceil(rightEdge))
    }
}
