import AppKit
import JavaScriptCore
import PDFKit
import SurimonoCore
import Testing

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
        _ body: String, layout: PrintLayout = .a4Single, fit: Bool = true, css: String = ""
    ) async throws -> RenderResult {
        _ = NSApplication.shared
        let renderer = DocumentRenderer(paginateWithResult: { request in
            var request = request
            if !fit { request.fitsTables = false }
            return try await WebPaginator().paginate(request)
        })
        let base = try theme
        let settings = RenderSettings(
            layout: layout, theme: PrintTheme(id: base.id, name: base.name, css: base.css + "\n" + css),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        return try await renderer.render(DocumentSource(data: Data(body.utf8), format: .markdown), settings: settings)
    }

    private func printPage(_ body: String, fit: Bool = true, css: String = "") async throws -> PDFPage {
        let document = try await printed(body, fit: fit, css: css).logicalDocument
        try #require(document.pageCount == 1)
        return try #require(document.page(at: 0))
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
        // A single glyph in the outside column measures its printed type independently of the border.
        let cells = (1..<40).map(String.init) + ["<span style='color:lime'>H</span>"]
        return head + String(repeating: row(cells), count: rows)
    }

    @Test("40列表だけを縮めて最後の列を刷り、外罫と本文の右端の間に余裕を残す", .timeLimit(.minutes(1)))
    func fortyColumns() async throws {
        let lead = "# Comparison\n\n<span style='color:blue'>H</span>\n\n"
        let control = try await Raster(printPage(lead))
        let page = try await printPage(lead + wideTable(rows: 1))
        let actual = try Raster(page)
        let body = try actual.bounds(channel: 2)
        #expect(try body == control.bounds(channel: 2))
        let last = try actual.bounds(channel: 1)
        let border = try actual.bounds(channel: 0)
        #expect(last.height < body.height && last.maxX <= border.minX)
        checkOutsideRule(border, pageWidth: page.bounds(for: .mediaBox).width)
    }

    @Test("右から左に読む40列表も表だけを縮め、両端の外罫を本文の幅の中に刷る", .timeLimit(.minutes(1)))
    func rightToLeft() async throws {
        func row(_ cells: [String]) -> String { "|" + cells.joined(separator: "|") + "|\n" }
        let lead = "مرحبا بالعالم\n\n"
        let table =
            row((1...40).map { "عمود\($0)" }) + row(Array(repeating: "---", count: 40))
            + row((1...40).map { "ق\($0)" })
        // Both outside rules are red here; the right one of the theme above marks an inner rule in this direction.
        let css =
            "th:last-child, td:last-child { border-right-color: black !important } "
            + "table { border-left: 5px solid red !important; border-right: 5px solid red !important }"
        let control = try await Raster(printPage(lead, css: css))
        let page = try await printPage(lead + table, css: css)
        let actual = try Raster(page)
        #expect(try actual.bounds(channel: 2) == control.bounds(channel: 2))
        let rules = try actual.bounds(channel: 0)
        let margin = 15 * 72 / 25.4 * 2
        let rightEdge = page.bounds(for: .mediaBox).width * 2 - margin
        #expect(rules.minX >= floor(margin) - 1)
        #expect(rules.maxX <= floor(rightEdge) - 1)
        // The table takes the whole column rather than being shrunk with the page.
        #expect(rules.width > rightEdge - margin - 24)
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
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            try #require(page.bounds(for: .mediaBox).width < 430)
            let pixels = try Raster(page)
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
        #expect(try fitted.bounds(channel: 2) == plain.bounds(channel: 2))
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
}
