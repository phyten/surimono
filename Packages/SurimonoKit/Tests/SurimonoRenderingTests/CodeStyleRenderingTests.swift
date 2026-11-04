import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct CodeStyleRenderingTests {
    private let longLine = String(repeating: "abcdefghij", count: 24)

    private func standard() throws -> PrintTheme {
        try #require(try PrintThemeLibrary.load().first { $0.id == "standard" })
    }

    private func settings(_ code: CodeStyle, textScale: Double = 1) throws -> RenderSettings {
        var settings = RenderSettings(
            layout: .a4Single, theme: try standard(), preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.code = code
        settings.textScale = textScale
        return settings
    }

    private func document(
        _ text: String, _ code: CodeStyle, format: DocumentFormat = .markdown, textScale: Double = 1
    ) async throws -> PDFDocument {
        _ = NSApplication.shared
        let source = DocumentSource(data: Data(text.utf8), format: format)
        return try await DocumentRenderer().render(source, settings: settings(code, textScale: textScale))
            .logicalDocument
    }

    private func lines(_ document: PDFDocument) -> [Substring] {
        (document.string ?? "").split(whereSeparator: \.isNewline)
    }

    /// How many characters print on a line at `textScale`: where a plain block wraps a long line in the real layout.
    private func fittingCharacters(textScale: Double) async throws -> Int {
        let wrapped = try await document(
            "```\n\(String(repeating: "m", count: 600))\n```\n", CodeStyle(), textScale: textScale)
        return try #require(lines(wrapped).first).count
    }

    /// The width of the text on the first page.
    private func textWidth(_ document: PDFDocument) throws -> CGFloat {
        let page = try #require(document.page(at: 0))
        let selection = try #require(page.selection(for: page.bounds(for: .mediaBox)))
        return selection.bounds(for: page).width
    }

    private func bounds(of text: String, in document: PDFDocument) throws -> CGRect {
        let selection = try #require(document.findString(text, withOptions: []).first)
        let page = try #require(selection.pages.first)
        return selection.bounds(for: page)
    }

    private func text(_ markdown: String, _ code: CodeStyle) async throws -> String {
        _ = NSApplication.shared
        let source = DocumentSource(data: Data(markdown.utf8), format: .markdown)
        let result = try await DocumentRenderer().render(source, settings: settings(code))
        return result.logicalDocument.string ?? ""
    }

    @Test("切る印は、紙に入らなかった文字の数を示す", .timeLimit(.minutes(1)))
    func cutMarkCountsHiddenCharacters() async throws {
        let style = CodeStyle(block: CodeBlockOptions(longLines: .cut), cutFormat: "+%d chars")
        let text = try await text("```\n\(longLine)\nshort\n```\n", style)
        let match = try #require(text.firstMatch(of: /\+(\d+) chars/))
        let hidden = try #require(Int(match.1))
        #expect(hidden > 20)
        #expect(hidden < longLine.count)
        #expect(text.contains("short"))
        #expect(!text.contains("short +"))
    }

    @Test("文字を縮めると、長い行が 1 行に収まる", .timeLimit(.minutes(1)))
    func shrinkKeepsOneLine() async throws {
        let line = String(repeating: "abcdefghij", count: 13)
        let wrapped = try await text("```\n\(line)\n```\n", CodeStyle())
        let shrunk = try await text("```\n\(line)\n```\n", CodeStyle(block: CodeBlockOptions(longLines: .shrink)))
        #expect(wrapped.split(whereSeparator: \.isNewline).count > 1)
        #expect(shrunk.split(whereSeparator: \.isNewline).count == 1)
    }

    @Test("行番号が紙に出る", .timeLimit(.minutes(1)))
    func lineNumbersPrint() async throws {
        let text = try await text("```\nfirst\nsecond\n```\n", CodeStyle(block: CodeBlockOptions(lineNumbers: .all)))
        #expect(text.contains("1"))
        #expect(text.contains("2"))
        #expect(text.contains("second"))
    }

    @Test("切る印は文字の大きさによらず、紙に入る行に付かず入らない行に付く", .timeLimit(.minutes(1)), arguments: [0.8, 1, 1.5, 2])
    func cutFollowsTextScale(textScale: Double) async throws {
        let style = CodeStyle(block: CodeBlockOptions(longLines: .cut), cutFormat: "+%d chars")
        let fit = try await fittingCharacters(textScale: textScale)
        func text(_ count: Int) async throws -> String {
            let line = String(repeating: "m", count: count)
            return try await document("```\n\(line)\n```\n", style, textScale: textScale).string ?? ""
        }
        #expect(try await !text(fit).contains("chars"))
        #expect(try await text(fit + 1).contains("chars"))
        let total = fit * 3
        let long = try await text(total)
        let match = try #require(long.firstMatch(of: /\+(\d+) chars/))
        let hidden = try #require(Int(match.1))
        // The mark takes the room of a few characters at the end of the line.
        #expect(total - hidden < fit)
        #expect(total - hidden > fit - 12)
    }

    @Test("文字を縮めるのは文字の大きさによらず、紙に入らない行のブロックだけで、幅いっぱいまで縮める", .timeLimit(.minutes(1)), arguments: [0.8, 1, 1.5, 2])
    func shrinkFollowsTextScale(textScale: Double) async throws {
        let style = CodeStyle(block: CodeBlockOptions(longLines: .shrink))
        let fit = try await fittingCharacters(textScale: textScale)
        let full = String(repeating: "m", count: fit)
        let plainWidth = try textWidth(try await document("```\n\(full)\n```\n", CodeStyle(), textScale: textScale))
        let fitting = try await document("```\n\(full)\n```\n", style, textScale: textScale)
        #expect(abs(try textWidth(fitting) - plainWidth) < 1)

        // Short of WebKit's smallest font, which at a small text size comes before the floor of the shrinking.
        let long = String(repeating: "m", count: fit * 9 / 8)
        let shrunk = try await document("```\n\(long)\n```\n", style, textScale: textScale)
        #expect(lines(shrunk).count == 1)
        #expect(try textWidth(shrunk) > plainWidth * 0.93)
        #expect(try textWidth(shrunk) <= plainWidth + 1)
    }

    @Test("トークンの途中の空の行も行の高さを保つ", .timeLimit(.minutes(1)), arguments: [CodeBlockOptions.LongLines.wrap, .cut])
    func blankLineInsideToken(longLines: CodeBlockOptions.LongLines) async throws {
        let style = CodeStyle(block: CodeBlockOptions(lineNumbers: .all, longLines: longLines))
        func gap(_ middle: String) async throws -> CGFloat {
            let code = "```swift\n/* firstline\n\(middle)\nlastline */\n```\n"
            let page = try await document(code, style)
            return try bounds(of: "firstline", in: page).minY - bounds(of: "lastline", in: page).minY
        }
        let blank = try await gap("")
        let filled = try await gap("middle")
        #expect(abs(blank - filled) < 1)
    }

    @Test("右上の言語名は、長い 1 行目に重ならない", .timeLimit(.minutes(1)), arguments: [CodeBlockOptions.Frame.none, .style, .rule])
    func cornerLabelLeavesTheFirstLine(frame: CodeBlockOptions.Frame) async throws {
        let style = CodeStyle(block: CodeBlockOptions(frame: frame, languageLabel: .corner))
        let page = try await document("```swift\n\(String(repeating: "m", count: 300))\n```\n", style)
        let label = try bounds(of: "Swift", in: page)
        let line = try bounds(of: "mmmmmmmm", in: page)
        #expect(label.minY >= line.maxY - 1)
    }

    @Test("Org の EXAMPLE も文字を縮めると 1 行に収まる", .timeLimit(.minutes(1)))
    func shrinkReachesOrgExample() async throws {
        let line = String(repeating: "m", count: 90)
        let org = "#+BEGIN_EXAMPLE\n\(line)\n#+END_EXAMPLE\n"
        let wrapped = try await document(org, CodeStyle(block: CodeBlockOptions(frame: .rule)), format: .org)
        let shrunk = try await document(org, CodeStyle(block: CodeBlockOptions(longLines: .shrink)), format: .org)
        #expect(lines(wrapped).count > 1)
        #expect(lines(shrunk).count == 1)
    }

    @Test("配色を変えると組み直し、同じ配色なら組み直さない", .timeLimit(.minutes(1)))
    func paletteIsPartOfTheCache() async throws {
        _ = NSApplication.shared
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let source = DocumentSource(data: Data("```\na\n```\n".utf8), format: .markdown)
        let sumi = try #require(try CodePaletteLibrary.load().first)
        _ = try await renderer.render(source, settings: settings(CodeStyle()))
        _ = try await renderer.render(source, settings: settings(CodeStyle()))
        #expect(renderer.logicalRenderCount == 1)
        _ = try await renderer.render(source, settings: settings(CodeStyle(palette: sumi)))
        #expect(renderer.logicalRenderCount == 2)
    }

    @Test("HTML 文書は配色を変えても組み直さない", .timeLimit(.minutes(1)))
    func htmlDocumentsIgnoreCodeStyle() async throws {
        _ = NSApplication.shared
        let renderer = DocumentRenderer(paginate: { _ in try RenderingFixtures.pdf() })
        let source = DocumentSource(data: Data("<pre><code>a</code></pre>".utf8), format: .html)
        let sumi = try #require(try CodePaletteLibrary.load().first)
        _ = try await renderer.render(source, settings: settings(CodeStyle()))
        _ = try await renderer.render(source, settings: settings(CodeStyle(palette: sumi)))
        #expect(renderer.logicalRenderCount == 1)
    }

    @Test("見本にも配色が効く", .timeLimit(.minutes(1)))
    func samplerUsesThePalette() async throws {
        _ = NSApplication.shared
        let dark = try #require(try CodePaletteLibrary.load().first { $0.id == "dark" })
        let source = DocumentSource(data: Data("```swift\nlet a = 1\n```\n".utf8), format: .markdown)
        let theme = try standard()
        let plain = try #require(try DocumentRenderer.themeSampler(for: source, settings: settings(CodeStyle())))
        let darkened = try #require(
            try DocumentRenderer.themeSampler(for: source, settings: settings(CodeStyle(palette: dark))))
        defer {
            plain.close()
            darkened.close()
        }
        #expect(try redness(try await plain.firstPage(for: theme)) > 200)
        #expect(try redness(try await darkened.firstPage(for: theme)) < 80)
    }

    /// The red of a point inside the code block, near the top of the text area. A sample draws itself, so its page
    /// has no content of its own to read.
    private func redness(_ page: PDFPage) throws -> UInt8 {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return bytes[(50 * width + 300) * 4]
    }

    @Test("文書にコードがあるかを形式を問わず読む")
    func detectsCode() {
        func source(_ text: String, _ format: DocumentFormat) -> DocumentSource {
            DocumentSource(data: Data(text.utf8), format: format)
        }
        #expect(DocumentRenderer.containsCode(source("```\na\n```\n", .markdown)))
        #expect(!DocumentRenderer.containsCode(source("# 見出し\n", .markdown)))
        #expect(DocumentRenderer.containsCode(source("#+BEGIN_SRC swift\na\n#+END_SRC\n", .org)))
        #expect(!DocumentRenderer.containsCode(source("a\nb\n", .plainText)))
        #expect(!DocumentRenderer.containsCode(source("<pre><code>a</code></pre>", .html)))
    }
}
