import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SourceTypesettingTests {
    private func settings(_ options: CodeBlockOptions? = nil) throws -> RenderSettings {
        var result = RenderSettings(
            layout: .a4Single, theme: try #require(PrintThemeLibrary.load().first { $0.id == "standard" }),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        result.code = CodeStyle(block: options)
        return result
    }

    private func file(_ text: String) -> DocumentSource {
        DocumentSource(data: Data(text.utf8), format: .plainText).named("source.swift")
    }

    @Test("字幅は一定で、行頭と行中のタブは四桁の位置、折り返しは字下げに二桁を足した位置に置く")
    func alignment() async throws {
        _ = NSApplication.shared
        let rulers =
            "|base\n" + String(repeating: "i", count: 16) + "|narrow\n" + String(repeating: "W", count: 16) + "|wide\n"
        let text = rulers + "\tBEGIN " + String(repeating: "word ", count: 24) + "END\na\tTAIL\n"
        let doc = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        let page = try #require(doc.page(at: 0))
        func box(_ word: String) throws -> CGRect {
            try #require(doc.findString(word).first).bounds(for: page)
        }
        // The first glyph of each marker is identical. Its position measures advance, independent of its ink bounds.
        let origin = try box("|base")
        let narrow = try box("|narrow").minX - origin.minX
        let wide = try box("|wide").minX - origin.minX
        #expect(narrow > 60)
        #expect(abs(narrow - wide) < 1)
        let column = narrow / 16
        #expect(abs(try box("BEGIN").minX - origin.minX - 4 * column) < 2)
        #expect(abs(try box("TAIL").minX - origin.minX - 4 * column) < 2)
        let lines = try #require(page.selection(for: page.bounds(for: .mediaBox))).selectionsByLine()
        let continuation = try #require(lines.first { $0.string?.contains("END") == true })
        #expect(abs(continuation.bounds(for: page).minX - origin.minX - 6 * column) < 2)
    }

    @Test("深い字下げの継続行は本文幅の半分から始まる")
    func deepIndent() async throws {
        _ = NSApplication.shared
        let options = try settings()
        let text = "origin\n" + String(repeating: " ", count: 64) + String(repeating: "word ", count: 40) + "END"
        let doc = try await DocumentRenderer().prepare(file(text), settings: options).logicalDocument
        let page = try #require(doc.page(at: 0))
        let origin = try #require(doc.findString("origin").first).bounds(for: page).minX
        let right = page.bounds(for: .mediaBox).maxX - 15 * 72 / 25.4
        let lines = try #require(page.selection(for: page.bounds(for: .mediaBox))).selectionsByLine()
        let last = try #require(lines.first { $0.string?.contains("END") == true })
        #expect(abs(last.bounds(for: page).minX - (origin + right) / 2) < 2)
    }

    @Test("一枚に収まる長さの元の行は、折り返しの途中で次の用紙へ送らない")
    func keepsRowsTogether() async throws {
        _ = NSApplication.shared
        let body = String(repeating: "word ", count: 42)
        let text = (0..<40).map { "FROM_\($0)_ " + body + " TO_\($0)_" }.joined(separator: "\n")
        let doc = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        #expect(doc.pageCount > 1)
        for index in 0..<40 {
            let first = try #require(doc.findString("FROM_\(index)_").first?.pages.first)
            let last = try #require(doc.findString("TO_\(index)_").first?.pages.first)
            #expect(doc.index(for: first) == doc.index(for: last))
        }
    }

    @Test("最小の文字倍率でもコードは8ptを保ち、印刷用PDFにも番号のインクが本文の左にある")
    func minimumAndGutter() async throws {
        _ = NSApplication.shared
        var small = try settings()
        small.textScale = 0.8
        let output = try await DocumentRenderer().render(file("MMMM\n"), settings: small)
        let logical = try #require(output.logicalDocument.page(at: 0))
        let selection = try #require(output.logicalDocument.findString("MMMM").first)
        let width = selection.bounds(for: logical).width
        // The standard face has a 0.602em advance. Allow subpixel PDF rounding.
        #expect(width / 4 >= 8 * 0.602 - 0.15)
        let left = try RenderingFixtures.inkColumns(logical).lowerBound
        #expect(CGFloat(left) + 3 < selection.bounds(for: logical).minX)
        let sheet = try #require(output.sheetDocument.page(at: 0))
        #expect(try RenderingFixtures.inkColumns(sheet).lowerBound == left)
    }

    @Test("印刷した行番号には数字の中の白が残り、1 と 8 のインク量が異なる")
    func printedDigits() async throws {
        _ = NSApplication.shared
        let output = try await DocumentRenderer().render(
            file(String(repeating: "ink\n", count: 8)), settings: settings())
        let page = try #require(output.sheetDocument.page(at: 0))
        try checkDigits(on: page)
    }

    private func checkDigits(on page: PDFPage) throws {
        // Read only the gutter, including a little white at both edges, at 288 dpi.
        let box = page.bounds(for: .mediaBox)
        let scale = 4
        let width = 10 * scale
        let height = Int(ceil(box.height)) * scale
        let bitmap = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        bitmap.translateBy(x: -(box.minX + 15 * 72 / 25.4 - 2), y: -box.minY)
        bitmap.drawPDFPage(try #require(page.pageRef))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var counts: [Int] = []
        var bounds = CGRect.null
        var count = 0
        for y in 0..<height {
            var hasInk = false
            for x in 0..<width where bytes[y * width + x] < 190 {
                hasInk = true
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                count += 1
            }
            if !hasInk && count > 0 {
                let coverage = CGFloat(count) / (bounds.width * bounds.height)
                #expect(coverage > 0.12 && coverage < 0.72)
                counts.append(count)
                count = 0
                bounds = .null
            }
        }
        try #require(counts.count == 8)
        #expect(Double(counts[7]) > 1.2 * Double(counts[0]))
        #expect(!(page.string ?? "").contains(where: { $0.isNumber }))
    }

    @Test("WebKit で印刷したソースは表示用のページ番号があっても、複数ページ・折り返し・タブ・和文を原文どおり選べる")
    func sourceSelections() async throws {
        _ = NSApplication.shared
        let wrapped = "START" + String(repeating: "abcdefghij", count: 20) + "END"
        let line = "let\tname = \"摺物\" // 日本語コメント"
        let text = line + " OK\r\n\t// " + wrapped + "\r\n" + String(repeating: "// 次の行\r\n", count: 120)
        let logical = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        try #require(logical.pageCount > 1)
        let plan = ViewPageLayout(
            pageCount: logical.pageCount,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: true)
        let displayed = try #require(ViewPageDocument.make(logical, plan: plan, margin: 0))
        for paper in [logical, displayed] {
            func copied(_ selection: PDFSelection) -> String? {
                SourcePaperText.selected(selection, in: logical, logicalIndex: { paper.index(for: $0) })
            }
            let first = try #require(paper.page(at: 0))
            let printed = try #require(first.string) as NSString
            func select(_ begin: String, _ end: String) throws -> PDFSelection {
                let left = printed.range(of: begin)
                let right = printed.range(of: end)
                try #require(left.location != NSNotFound && right.location != NSNotFound)
                return try #require(first.selection(for: NSUnionRange(left, right)))
            }
            let across = try select("START", "END")
            #expect(across.selectionsByLine().count > 1)
            func escaped(_ value: String?) -> String {
                guard let value else { return "nil" }
                let ascii = value.unicodeScalars.prefix(260).map { $0.escaped(asASCII: true) }.joined()
                return "\"" + ascii.replacing(/(?:abcdefghij){2,}/) { "〔abcdefghij×\($0.0.count / 10)〕" } + "\""
            }
            func diagnostic(_ outcome: String) -> String {
                let requested = NSUnionRange(printed.range(of: "START"), printed.range(of: "END"))
                let context = NSIntersectionRange(
                    NSRange(location: max(0, requested.location - 6), length: requested.length + 12),
                    NSRange(location: 0, length: printed.length))
                func ranges(_ selection: PDFSelection) -> String {
                    (0..<selection.numberOfTextRanges(on: first)).map {
                        NSStringFromRange(selection.range(at: $0, on: first))
                    }.joined(separator: ",")
                }
                let lines = across.selectionsByLine().map { ranges($0) }.joined(separator: "/")
                return "\(paper === logical ? "logical" : "displayed") \(outcome); requested=\(requested) "
                    + "ranges=\(ranges(across)) lines=\(lines) selection=\(escaped(across.string)) "
                    + "page=\(escaped(printed.substring(with: context)))"
            }
            let actual = copied(across)
            if actual != wrapped { Issue.record("\(diagnostic("copied=" + escaped(actual)))") }
            #expect(try copied(select("let", "コメント")) == line)
            let all = PDFSelection(document: paper)
            for i in 0..<paper.pageCount {
                let page = try #require(paper.page(at: i))
                all.add(try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))))
            }
            let restored = copied(all)
            if restored != text {
                let details = (0..<paper.pageCount).compactMap { index -> String? in
                    guard let page = paper.page(at: index) else { return nil }
                    let ranges = (0..<all.numberOfTextRanges(on: page)).map { all.range(at: $0, on: page) }
                    return
                        "\(index): chars=\(page.numberOfCharacters)/\(page.string?.utf16.count ?? 0) ranges=\(ranges) last=\(escaped(page.string.map { String($0.suffix(12)) }))"
                }
                Issue.record("\(paper === logical ? "logical" : "displayed") pages=\(all.pages.count) \(details)")
            }
        }
    }

    @Test("空行だけの紙が続くときは、最初の紙のコピーに後続ページの空行を足さない")
    func firstPageBeforeBlankPages() async throws {
        _ = NSApplication.shared
        let text = "A\n" + String(repeating: "\n", count: 200) + "B\n"
        let pdf = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        try #require(pdf.pageCount > 2)
        let page = try #require(pdf.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)))
        #expect(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "A")
        #expect(SourcePaperText.selected(selection, in: pdf, logicalIndex: { pdf.index(for: $0) }) == nil)
    }

    @Test("空行だけの紙を挟んでも、前後の紙の本文を選ぶと原文のタブが戻る")
    func selectionsAroundBlankPages() async throws {
        _ = NSApplication.shared
        let text = "abc\n" + String(repeating: "\n", count: 200) + "let\tvalue = 1\n"
        let pdf = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        try #require(pdf.pageCount > 2)
        let first = try #require(pdf.findString("b").first)
        let last = try #require(pdf.findString("value").first?.pages.first)
        try #require(pdf.index(for: last) > 1)
        let printed = try #require(last.string) as NSString
        let begin = printed.range(of: "let")
        let end = printed.range(of: "value")
        try #require(begin.location != NSNotFound && end.location != NSNotFound)
        let tail = try #require(last.selection(for: NSUnionRange(begin, end)))
        #expect(SourcePaperText.selected(tail, in: pdf, logicalIndex: { pdf.index(for: $0) }) == "let\tvalue")
        #expect(SourcePaperText.selected(first, in: pdf, logicalIndex: { pdf.index(for: $0) }) == "b")
    }

    @Test("用紙よりも長い元の一行は複数ページに分かれ、文字数と前後の目印を保つ")
    func splitsOversizeLine() async throws {
        _ = NSApplication.shared
        let text = "START" + String(repeating: "x", count: 14_000) + "END"
        let doc = try await DocumentRenderer().prepare(file(text), settings: settings()).logicalDocument
        #expect(doc.pageCount > 1)
        #expect((doc.string ?? "").filter { !$0.isWhitespace } == text)
    }

    @Test("長い行を縮めると標準の紙で一行に収まり、切る指定でも HTML の本文は欠けない")
    func fittingAndExport() async throws {
        _ = NSApplication.shared
        let text = String(repeating: "w", count: 92)
        let shrunk = try await DocumentRenderer().prepare(
            file(text), settings: settings(.init(frame: .none, lineNumbers: .all, longLines: .shrink)))
        let page = try #require(shrunk.logicalDocument.page(at: 0))
        let selection = try #require(page.selection(for: page.bounds(for: .mediaBox)))
        #expect(selection.selectionsByLine().count == 1)
        let original = "\t" + text + text + "\n\n"
        let exported = try await HTMLExporter.html(
            source: file(original), settings: settings(.init(frame: .none, lineNumbers: .all, longLines: .cut)),
            title: "sample")
        let pre = try #require(exported.firstMatch(of: /(?s)<pre class="surimono-source[^>]*>(.*?)<\/pre>/))
        #expect(String(pre.1).replacing(/<[^>]+>/, with: "") == original)
    }
}
