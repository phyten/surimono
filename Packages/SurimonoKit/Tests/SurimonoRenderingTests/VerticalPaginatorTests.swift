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

    @Test("縦書きは見出しと本文二行を同じ段に置き、冊子の章は次のページを開く")
    func verticalHeadings() {
        let lines = [
            Band(start: 0, end: 10), Band(start: 11, end: 17, keepNext: true),
            Band(start: 18, end: 24), Band(start: 25, end: 31),
            Band(start: 32, end: 36, keepNext: true, chapter: true), Band(start: 37, end: 40),
        ]
        let pages = VerticalPaginator.rows(for: lines, capacity: 26, rowsPerPage: 2)
        #expect(pages == [[Band(start: 0, end: 10), Band(start: 11, end: 31)], [Band(start: 32, end: 40)]])
        #expect(
            VerticalPaginator.rows(for: lines, capacity: 100, rowsPerPage: 2) == [
                [Band(start: 0, end: 31)], [Band(start: 32, end: 40)],
            ])
    }

    @Test("論理 A4 は上下に同寸の版面と三字分の段間を取り、A5 は一段になる")
    func rowFrames() {
        let margins = WebPaginator.Margins(top: 36, left: 45, bottom: 54, right: 36)
        let a4 = VerticalPaginator.Frame(pageSize: PaperSize.a4.size, margins: margins, textScale: 1)
        #expect(a4.rows == 2 && a4.font == 10.5)
        #expect(a4.width == 441 && a4.height == 315)
        let extraTop = PaperSize.a4.size.height - a4.top(of: 0) - margins.top
        let extraBottom = a4.top(of: 1) - a4.height - margins.bottom
        #expect(abs(extraTop - extraBottom) < 0.001)
        #expect(extraTop > a4.font)
        let scaled = VerticalPaginator.Frame(pageSize: PaperSize.a4.size, margins: margins, textScale: 1.25)
        #expect(scaled.width == 436.40625 && scaled.height == 315)
        #expect(scaled.top(of: 0) - scaled.height - scaled.top(of: 1) == 39.375)
        #expect(a4.top(of: 0) - a4.height - a4.top(of: 1) == 31.5)
        let a5 = VerticalPaginator.Frame(pageSize: PaperSize.a5.size, margins: margins, textScale: 1)
        #expect(a5.rows == 1 && a5.font == 10.5)
        #expect(a5.width == 330.75 && a5.height == 441)
        let narrow = VerticalPaginator.Frame(
            pageSize: PaperSize.a5.size, margins: .init(top: 90, left: 76, bottom: 90, right: 76), textScale: 1)
        #expect(narrow.width == 257.25 && narrow.height == 409.5)
    }

    @Test("切片の割当は小数の配置幅で決め、重なる傍点とルビの描画範囲だけを広げる")
    func overlappingInk() {
        let first = Band(start: 0.25, end: 10.25, ink: .init(start: -3.5, end: 13.75, top: -0.5, bottom: 21))
        let second = Band(start: 11.25, end: 20.75, ink: .init(start: 8, end: 23.125, top: 0, bottom: 23.5))
        #expect(VerticalPaginator.rows(for: [first, second], capacity: 20, rowsPerPage: 2) == [[first, second]])
        let merged = Band(start: 0.25, end: 20.75, ink: .init(start: -3.5, end: 23.125, top: -0.5, bottom: 23.5))
        #expect(VerticalPaginator.rows(for: [first, second], capacity: 20.5, rowsPerPage: 2) == [[merged]])
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
    @Test("同じ A5 の二ページ配置から右とじ冊子に替えると、章の前で改ページする指定で組み直す", .timeLimit(.minutes(1)))
    func bookletChapterCache() async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        var settings = RenderSettings(
            layout: .a4TwoUp, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let source = DocumentSource(data: Data("# 春\n\n本文\n\n# 秋\n\n本文".utf8), format: .markdown)
        var bookletRequests: [Bool] = []
        let renderer = DocumentRenderer(paginate: { request in
            bookletRequests.append(request.verticalBooklet)
            return try RenderingFixtures.pdf(size: request.pageSize)
        })
        _ = try await renderer.prepare(source, settings: settings)
        settings.layout = PrintLayout.a4BookletA5.bound(.right)
        _ = try await renderer.prepare(source, settings: settings)
        #expect(bookletRequests == [false, true])
    }

    @Test(
        "A4・A5 の行長と横組みの箱を保ち、冊子では次の章を新しいページから始める", .timeLimit(.minutes(1)),
        arguments: [PrintLayout.a4Single, .a4TwoUp, .a4BookletA5])
    func typography(layout: PrintLayout) async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "tategaki" })
        // Enough prose on A4 makes the horizontal boxes follow the upper row.
        let count = layout.kind == .normal ? 770 : 80
        let heading = #"<h1 style="color: #008000">新章</h1><p>本文</p>"#
        let cells = ["本", "11", "25", "12", "50", "!?"].map {
            #"<span class="cell" style="white-space: nowrap"><span>本</span>\#($0)<span>本</span></span>"#
        }.joined()
        let a5Probe = layout.kind != .normal
        let indent = a5Probe ? " style=\"text-indent:0.5em\"" : ""
        let body = """
            <p id="prose"\(indent)>\(String(repeating: "本", count: count))\(a5Probe ? "<br>本本" : "")</p>
            <p id="numbers">2026年11月25日、12段落、50%、本当か!?　1段落目、10kg、3.14、1,234円。</p>
            <p>\(cells)</p>
            <table><tr><td style="color: blue">表</td></tr></table>
            <pre><code style="color: red">let a = 1</code></pre><p id="next">次</p>
            """
        let booklet = layout.kind == .booklet
        let paper: PaperSize = layout.kind == .normal ? .a4 : .a5
        let size = layout.logicalPageSize
        let margins = WebPaginator.Margins(top: 36, left: 45, bottom: 54, right: 36)
        let html = HTMLDocumentBuilder.build(
            fragment: HTMLFragment(body: paper == .a4 ? heading + body : body + heading),
            format: .markdown, theme: theme)
        let view = WKWebView(frame: CGRect(origin: .zero, size: size))
        let navigation = NavigationTracker()
        view.navigationDelegate = navigation
        view.loadHTMLString(html, baseURL: nil)
        try await WebPaginator.waitUntil(timeout: .seconds(10)) { navigation.state != .loading }
        try #require(navigation.state == .finished)
        let document = try await VerticalPaginator.pages(
            in: view, pageSize: size, margins: margins, timeout: .seconds(10), booklet: booklet)
        #expect(document.pageCount == (booklet ? 2 : 1))
        let rowWidth = paper == .a4 ? 441.0 : 330.75
        let rowHeight: CGFloat = paper == .a4 ? 315 : 441
        let script = """
            const range = document.createRange();
            const prose = document.querySelector('#prose');
            const firstText = document.createTreeWalker(prose, NodeFilter.SHOW_TEXT).nextNode();
            range.selectNodeContents(firstText);
            const firstLine = range.getClientRects()[0];
            const numbers = document.querySelector('#numbers');
            const short = [...numbers.querySelectorAll('.tcy')];
            // Identical surrounding glyphs isolate the advance from font side bearings.
            const advances = [...document.querySelectorAll('.cell')].map(cell => {
                const first = cell.firstElementChild.getBoundingClientRect();
                const last = cell.lastElementChild.getBoundingClientRect();
                return Math.abs(first.left - last.left) < 1 ? last.top - first.top : -1;
            });
            const em = parseFloat(getComputedStyle(numbers).fontSize);
            const strip = document.querySelector('.surimono-vertical').getBoundingClientRect();
            const rowHeight = strip.height;
            const tableBox = document.querySelector('table');
            const codeBox = document.querySelector('pre');
            const table = tableBox.getBoundingClientRect();
            const code = document.querySelector('pre').getBoundingClientRect();
            const next = document.querySelector('#next').getBoundingClientRect();
            let a5 = [];
            if (prose.querySelector('br')) {
                // Half a cell of indent forces inter-character justification even on a whole-cell grid.
                const origin = prose.getBoundingClientRect().top;
                const lines = [];
                const walker = document.createTreeWalker(prose, NodeFilter.SHOW_TEXT);
                for (let n=walker.nextNode(); n; n=walker.nextNode()) {
                    for (let i=0; i<n.length; ++i) {
                        range.setStart(n,i); range.setEnd(n,i+1);
                        const r=range.getBoundingClientRect();
                        if (!lines.length || Math.abs(lines.at(-1).x-r.left)>em/2) lines.push({x:r.left, y:[]});
                        lines.at(-1).y.push((r.top-origin)/em);
                    }
                }
                a5 = lines.map(l => l.y);
            }
            return {
                a5, fontSizeCSSPx:em, lineLengthCSSPx:rowHeight,
                fullHeight: firstLine.bottom > strip.bottom - em - 1 && firstLine.bottom <= strip.bottom + 1
                    && Math.abs(rowHeight - contentHeight) < 1,
                containedBoxes: [tableBox, codeBox].every(box => {
                    const rect = box.getBoundingClientRect();
                    return getComputedStyle(box).writingMode === 'horizontal-tb'
                        && rect.top >= strip.top-1 && rect.bottom <= strip.bottom + 1
                        && rect.width <= parseFloat(getComputedStyle(box).maxInlineSize) + 1;
                }),
                separateBoxes: table.left > code.right && code.left > next.right,
                alignedTops: Math.abs(table.top - prose.getBoundingClientRect().top) < 1 && Math.abs(table.top - code.top) < 1,
                shortDigits: short.map(e => e.textContent).join(',') === '11,25,12,!?'
                    && short.every(e => {
                        const style = getComputedStyle(e);
                        return style.display === 'inline' && (style.textCombineUpright === 'all'
                            || style.getPropertyValue('-webkit-text-combine') === 'horizontal');
                    }),
                advances, em,
                mixedYear: numbers.querySelector('.v-latin')?.textContent === '2026',
                mixedProse: getComputedStyle(numbers).textOrientation === 'mixed'
            };
            """
        let contentHeight = rowHeight * 96 / 72
        let measured = try #require(
            try await view.callAsyncJavaScript(
                script, arguments: ["contentHeight": contentHeight], in: nil,
                contentWorld: WebPaginator.preparationWorld) as? [String: Any])
        for property in [
            "fullHeight", "containedBoxes", "separateBoxes", "alignedTops", "shortDigits", "mixedYear", "mixedProse",
        ] {
            #expect(measured[property] as? Bool == true, "\(property)")
        }
        let advances = try #require(measured["advances"] as? [Double])
        let em = try #require(measured["em"] as? Double)
        if a5Probe {
            let lines = try #require(measured["a5"] as? [[Double]])
            try #require(lines.count == 3)
            let width = contentHeight / em
            let rows = lines.map { ($0.last ?? 0) + 1 }
            #expect(abs(rows[0] - width) < 0.12)
            #expect(abs((lines[0].first ?? 0) - 0.5) < 0.12)
            for line in lines.suffix(2) {
                #expect(abs(line.first ?? 0) < 0.12)
                #expect(abs((line.last ?? 0) - Double(line.count - 1)) < 0.12)
            }
            let data = try JSONSerialization.data(withJSONObject: measured, options: [.prettyPrinted, .sortedKeys])
            Attachment.record(String(decoding: data, as: UTF8.self), named: "vertical-spacing-\(layout.id).json")
        }
        let labels = ["本", "11", "25", "12", "50", "!?"]
        try #require(advances.count == labels.count)
        #expect(abs(advances[0] - 2 * em) < 1.5, "本文の字送り \(advances[0]) px、2 字分 \(2 * em) px")
        for (label, advance) in zip(labels.dropFirst(), advances.dropFirst()) {
            #expect(abs(advance - advances[0]) < 1.5, "「本\(label)本」の字送り \(advance) px、基準 \(advances[0]) px")
        }
        let right = (margins.left + size.width - margins.right + rowWidth) / 2
        let font = 10.5
        let page = try #require(document.page(at: 0))
        let first = try PagePixels(page)
        let isChapter: (Int, Int, Int) -> Bool = { r, g, b in g > r + 55 && g > b + 55 }
        let chapterPage: PagePixels
        if booklet {
            #expect(first.bounds(where: isChapter) == nil)
            chapterPage = try PagePixels(#require(document.page(at: 1)))
            let following = try #require(
                chapterPage.bounds { r, g, b in max(r, g, b) < 128 && max(r, g, b) - min(r, g, b) < 24 })
            #expect(following.maxX < right - font)
        } else {
            chapterPage = first
        }
        let chapter = try #require(chapterPage.bounds(where: isChapter))
        if layout.kind == .twoUp {
            #expect(chapter.maxX < right - 2 * font)
        } else {
            #expect(abs(chapter.maxX - right) < font)
        }
        if paper == .a4 {
            // Ink on the finished page includes the translation that places the second capture below the first.
            let code = try #require(first.bounds { r, g, b in r > g + 80 && r > b + 80 })
            let table = try #require(first.bounds { r, g, b in b > r + 80 && b > g + 80 })
            let extra = (size.height - margins.top - margins.bottom - 2 * rowHeight - 31.5) / 2
            let lowerTop = margins.top + extra + rowHeight + 31.5
            let lower = CGRect(x: 0, y: margins.bottom + extra, width: size.width, height: rowHeight)
            let lowerInk = try printedInk(in: lower, on: page, scale: 2)
            #expect(abs(lowerInk.maxX - chapter.maxX) < font / 2)
            #expect(code.minY >= lowerTop && code.maxY <= size.height - margins.bottom)
            #expect(table.maxY <= margins.top + extra + rowHeight || table.minY >= lowerTop)
            #expect([code, table].allSatisfy { $0.minX >= right - rowWidth && $0.maxX <= right + 1 })
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
        // Each explicit source line needs at least one column, even before longer paragraphs wrap.
        try #require(document.pageCount >= 60, "\(metrics)")

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
            var pageText = ""
            for upper in [true, false] {
                let middle = content.midY
                let band = CGRect(
                    x: content.minX, y: upper ? middle : content.minY, width: content.width, height: content.height / 2)
                let row = glyphs.filter { band.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                if index == 0 { #expect(!row.isEmpty) }
                var columns: [CGRect] = []
                for glyph in row.sorted(by: { $0.maxX > $1.maxX }) {
                    if let last = columns.indices.last, glyph.maxX > columns[last].minX {
                        columns[last] = columns[last].union(glyph)
                    } else {
                        columns.append(glyph)
                    }
                }
                for column in columns {
                    let strip = CGRect(x: column.minX - 1, y: band.minY, width: column.width + 2, height: band.height)
                    let selection = try #require(page.selection(for: strip))
                    pageText += (selection.string ?? "").filter { !$0.isWhitespace }
                }
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
