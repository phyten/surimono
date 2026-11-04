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

    private func settings(_ code: CodeStyle) throws -> RenderSettings {
        var settings = RenderSettings(
            layout: .a4Single, theme: try standard(), preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.code = code
        return settings
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
