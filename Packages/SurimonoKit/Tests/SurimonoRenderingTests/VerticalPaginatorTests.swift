import AppKit
import OSLog
import PDFKit
import SurimonoCore
import Testing
import WebKit

@testable import SurimonoRendering

struct FlowPageCutsTests {
    typealias Band = FlowPageCuts.Band

    @Test("重なった文字とルビを同じ行にまとめ、収まる最後の行の後で区切る")
    func overlappingFragments() {
        let fragments = [Band(start: 22, end: 31), Band(start: 1, end: 9), Band(start: 8, end: 12)]
        #expect(
            FlowPageCuts.pages(for: fragments, capacity: 28) == [Band(start: 1, end: 12), Band(start: 22, end: 31)])
        #expect(FlowPageCuts.pages(for: fragments, capacity: 30) == [Band(start: 1, end: 31)])
    }

    @Test("末尾の見出しを次のページの本文と一緒に送る")
    func keepsHeadingWithText() {
        let bands = [Band(start: 0, end: 12), Band(start: 16, end: 24, keepNext: true), Band(start: 28, end: 38)]
        #expect(FlowPageCuts.pages(for: bands, capacity: 26) == [Band(start: 0, end: 12), Band(start: 16, end: 38)])
    }

    @Test("用紙より広い箱は分けずに単独のページに取り、空の帯は空のまま返す")
    func oversizeBox() {
        let bands = [Band(start: 0, end: 4), Band(start: 7, end: 77), Band(start: 85, end: 95)]
        #expect(FlowPageCuts.pages(for: bands, capacity: 40) == bands)
        #expect(FlowPageCuts.pages(for: [], capacity: 40).isEmpty)
    }
}

@MainActor
struct FlowPageCaptureTests {
    @Test("移動・縮小した PDF 片ではノンブルの同じ字形だけを仕上がり座標で照合する")
    func printedDigit() async throws {
        let slice = try RenderingFixtures.pdf(size: CGSize(width: 240, height: 120))
        let page = try #require(slice.page(at: 0))
        let digit = page.numberOfCharacters - 1
        try #require(digit >= 0)
        let ink = page.characterBounds(at: digit)
        let data = try #require(slice.dataRepresentation())
        let target = CGRect(x: 30, y: 12, width: 120, height: 60)
        let point = CGPoint(x: 30 + ink.midX / 2, y: 12 + ink.midY / 2)
        _ = try await PDFDrawing.document(pageSize: CGSize(width: 160, height: 90)) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            let printed = try FlowPageCapture.draw(data, into: target, in: context)
            let bounds = try #require(printed.glyphBounds(of: "1", at: point))
            #expect(abs(bounds.minY - (12 + ink.minY / 2)) < 0.01)
            #expect(abs(bounds.height - ink.height / 2) < 0.01)
            #expect(printed.glyphBounds(of: "2", at: point) == nil)
        }
    }

    @Test("切り出したベクトル文字を余白の内側に置き、右とじの用紙でも文字とノンブルを読める")
    func selectableAfterImposition() async throws {
        let slice = try #require(try RenderingFixtures.pdf(size: CGSize(width: 240, height: 120)).dataRepresentation())
        let target = CGRect(x: 285, y: 680, width: 180, height: 90)
        let logical = try await PDFDrawing.document(pageSize: PaperSize.a4.size) { context in
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            try FlowPageCapture.draw(slice, into: target, in: context)
        }
        let page = try #require(logical.page(at: 0))
        #expect(page.string == "PAGE-1")
        #expect(page.selection(for: target)?.string == "PAGE-1")
        let sheets = try await PDFComposer().compose(
            logical, layout: PrintLayout.a3BookletA4.bound(.right), options: PrintOptions(showsPageNumbers: true))
        let front = try #require(sheets.page(at: 0))
        #expect(front.selection(for: target)?.string == "PAGE-1")
        let footer = CGRect(x: 0, y: 0, width: 595, height: 42)
        #expect(front.selection(for: footer)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }
}

@MainActor
struct VerticalPaginatorTests {
    @Test("本文は余白いっぱいまで縦に流れ、数字の向きと表・コードの独立した行を保つ", .timeLimit(.minutes(1)), arguments: [PaperSize.a4, .a5])
    func typography(paper: PaperSize) async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let body = """
            <p id="prose">\(String(repeating: "本", count: 180))</p>
            <p id="numbers">2026年11月19日、A4 で 12 ページ。ABC12 Surimono</p>
            <table><tr><td>表</td></tr></table><pre><code>let a = 1</code></pre><p id="next">次</p>
            """
        let size = paper.size
        let margins = WebPaginator.Margins(top: 36, left: 45, bottom: 54, right: 36)
        let html = HTMLDocumentBuilder.build(fragment: HTMLFragment(body: body), format: .markdown, theme: theme)
        let view = WKWebView(frame: CGRect(origin: .zero, size: size))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(10)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        let document = try await VerticalPaginator.pages(
            in: view, pageSize: size, margins: margins, timeout: .seconds(10))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let twelves = document.findString("12", withOptions: [])
        try #require(twelves.count == 2)
        for selection in twelves {
            let range = selection.range(at: 0, on: page)
            try #require(range.length >= 2)
            let one = try #require(page.selection(for: NSRange(location: range.location, length: 1)))
            let two = try #require(page.selection(for: NSRange(location: range.location + 1, length: 1)))
            #expect(one.string == "1" && two.string == "2")
            let left = one.bounds(for: page)
            let right = two.bounds(for: page)
            #expect(abs(left.midY - right.midY) < 1 && left.midX < right.minX)
        }

        let script = """
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('#prose'));
            const firstLine = range.getClientRects()[0];
            const numbers = document.querySelector('#numbers');
            const short = [...numbers.querySelectorAll('.tcy')];
            const year = numbers.querySelector('.upright-digits');
            const table = document.querySelector('table').getBoundingClientRect();
            const code = document.querySelector('pre').getBoundingClientRect();
            const next = document.querySelector('#next').getBoundingClientRect();
            return {
                fullHeight: firstLine.height > contentHeight - 16 && firstLine.height <= contentHeight + 1,
                separateBoxes: table.left > code.right && code.left > next.right,
                alignedTops: table.top > 0 && Math.abs(table.top - code.top) < 1,
                shortDigits: short.map(e => e.textContent).join(',') === '11,19,4,12,12'
                    && short.every(e => getComputedStyle(e).textCombineUpright === 'all'),
                uprightYear: year.textContent === '2026' && getComputedStyle(year).textOrientation === 'upright',
                mixedProse: getComputedStyle(numbers).textOrientation === 'mixed'
            };
            """
        let contentHeight = (size.height - margins.top - margins.bottom) * 96 / 72
        let measured = try #require(
            try await view.callAsyncJavaScript(
                script, arguments: ["contentHeight": contentHeight], in: nil,
                contentWorld: WebPaginator.preparationWorld) as? [String: Bool])
        for property in ["fullHeight", "separateBoxes", "alignedTops", "shortDigits", "uprightYear", "mixedProse"] {
            #expect(measured[property] == true, "\(property)")
        }
    }

    @Test("縦書きの組版中に WebContent のプロセスが終わっていたら、締切を待たずに終了のエラーになる", .timeLimit(.minutes(1)))
    func webContentEnded() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let size = PaperSize.a5.size
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: "<p>本文</p>"), format: .markdown, theme: theme)
        let view = WKWebView(frame: CGRect(origin: .zero, size: size))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(15)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        // Only this test's web view is ended (see `webContentEndsDuringSnapshot`).
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        try #require(view.responds(to: kill))
        view.perform(kill)
        try await WebPaginator.waitUntil(timeout: .seconds(15)) { navigation.terminationError != nil }
        let started = ContinuousClock.now
        let termination = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
        // The timeout is far beyond the test's limit: the error must come from the ended process, not the deadline.
        await #expect(throws: WebPaginator.PaginationError.loadFailed(termination.localizedDescription)) {
            _ = try await VerticalPaginator.pages(
                in: view, pageSize: size, margins: .init(top: 36, left: 36, bottom: 36, right: 36),
                timeout: .seconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("縦書き三千行が読む順の選択可能な文字で余白に収まり、面付けにも渡る", .timeLimit(.minutes(1)))
    func novel() async throws {
        _ = NSApplication.shared
        let digits = Array("〇一二三四五六七八九")
        let lines = (0..<3000).map { i in
            let label = String([digits[i / 1000], digits[i / 100 % 10], digits[i / 10 % 10], digits[i % 10]])
            let text = "庭の桜は朝の光を浴びていた。"
            return label + String(repeating: text, count: i.isMultiple(of: 31) ? 6 : 2)
        }
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let source = DocumentSource(data: Data(lines.joined(separator: "\n").utf8), format: .plainText)
        let renderer = DocumentRenderer()
        let start = ContinuousClock.now
        let prepared = try await renderer.prepare(source, settings: settings)
        let elapsed = ContinuousClock.now - start
        let document = prepared.logicalDocument
        let metrics = "3000 lines, \(document.pageCount) logical pages, \(elapsed)"
        Logger(subsystem: "app.surimono.Surimono", category: "VerticalPaginatorTests")
            .notice("\(metrics, privacy: .public)")
        #expect(elapsed < .seconds(8), "\(metrics)")
        try #require((90...150).contains(document.pageCount), "\(metrics)")

        let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
        let size = settings.layout.logicalPageSize(options: settings.options)
        let content = CGRect(
            x: margins.left, y: margins.bottom, width: size.width - margins.left - margins.right,
            height: size.height - margins.top - margins.bottom)
        var extracted = ""
        var logicalTexts: [String] = []
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let text = try #require(page.string)
            try #require(!text.isEmpty)
            logicalTexts.append(text)
            // PDFKit inserts line feeds in its string and supplies empty bounds for synthetic characters.
            // A short final page can be returned in left-to-right column order by a whole-page selection.
            let glyphs = (0..<page.numberOfCharacters).map(page.characterBounds(at:)).filter { !$0.isEmpty }
            let ink = glyphs.reduce(CGRect.null) { $0.union($1) }
            var columns: [CGRect] = []
            for glyph in glyphs.sorted(by: { $0.maxX > $1.maxX }) {
                if let last = columns.indices.last, glyph.maxX > columns[last].minX {
                    columns[last] = columns[last].union(glyph)
                } else {
                    columns.append(glyph)
                }
            }
            var pageText = ""
            for column in columns {
                let strip = CGRect(x: column.minX - 1, y: 0, width: column.width + 2, height: size.height)
                let selection = try #require(page.selection(for: strip))
                pageText += (selection.string ?? "").filter { !$0.isWhitespace }
            }
            #expect(glyphs.count == pageText.count)
            #expect(pageText.count == text.filter { !$0.isWhitespace }.count)
            extracted += pageText
            #expect(abs(page.bounds(for: .mediaBox).width - size.width) < 0.1)
            #expect(abs(page.bounds(for: .mediaBox).height - size.height) < 0.1)
            #expect(!ink.isEmpty && content.insetBy(dx: -0.5, dy: -0.5).contains(ink), "ページ \(index + 1) \(ink)")
        }
        let matchesSource = extracted == lines.joined()
        #expect(matchesSource, "選択した全 \(extracted.count) 文字が原文の順になる")
        let sheets = try await renderer.composeSheet(for: prepared)
        try #require(sheets.sheetDocument.pageCount == document.pageCount)
        for (index, text) in logicalTexts.enumerated() {
            #expect(sheets.sheetDocument.page(at: index)?.string == text, "用紙 \(index + 1)")
        }
    }
}
