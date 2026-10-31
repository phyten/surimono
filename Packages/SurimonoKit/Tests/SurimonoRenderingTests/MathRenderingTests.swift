import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct MathRenderingTests {
    @Test("Markdown の数式は KaTeX の書体で紙に刷られ、ほかの文と同じページに入る", .timeLimit(.minutes(1)))
    func mathPrintsWithKaTeXFonts() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let markdown = "# 数式\n\n本文の $E = mc^2$ と\n\n$$\n\\int_0^1 x\\,dx = \\frac{1}{2}\n$$\n\n後の文"
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings)
        #expect(result.logicalDocument.pageCount == 1)
        let page = try #require(result.logicalDocument.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("本文の"))
        #expect(text.contains("後の文"))
        // The formulas' glyphs are text in the embedded KaTeX fonts, not outlines or a fallback font. PDFKit does not
        // report embedded subset fonts by name, so the PDF's font dictionaries are read instead.
        let pdf = String(decoding: try #require(result.logicalDocument.dataRepresentation()), as: UTF8.self)
        #expect(pdf.contains("+KaTeX_Math-Italic"))
        #expect(pdf.contains("+KaTeX_Main-Regular"))
    }

    @Test("LaTeX 風のテーマは、欧文と等幅を同梱の Computer Modern で、和文を明朝で刷る", .timeLimit(.minutes(1)))
    func latexThemePrintsComputerModern() async throws {
        _ = NSApplication.shared
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex" })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: HTMLCleanupPreset(id: "none", name: "None"))
        let markdown = "# Title\n\nThe quick brown fox と日本語の文、**bold** と `code`。"
        let result = try await DocumentRenderer().render(
            DocumentSource(data: Data(markdown.utf8), format: .markdown), settings: settings)
        let pdf = String(decoding: try #require(result.logicalDocument.dataRepresentation()), as: UTF8.self)
        #expect(pdf.contains("+KaTeX_Main-Regular"))
        #expect(pdf.contains("+KaTeX_Main-Bold"))
        #expect(pdf.contains("+KaTeX_Typewriter-Regular"))
        #expect(pdf.contains("HiraMinProN"))
    }
}
