import AppKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct HTMLExporterTests {
    @Test("HTML とリッチテキストには選んだ欧文書体を埋め込む", .timeLimit(.minutes(1)))
    func typefaceForExportAndCopy() async throws {
        let source = DocumentSource(data: Data("# Western 本文\n\n`code`".utf8), format: .markdown)
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let settings = RenderSettings(
            layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None"), typeface: .latex)
        let html = try await HTMLExporter.html(source: source, settings: settings, title: "Example")
        let rich = try await HTMLExporter.richText(source: source, settings: settings, title: "Example")
        for output in [html, rich.html] {
            #expect(output.contains("Surimono Computer Modern Typewriter"))
            #expect(output.contains("Andrey V. Panov"))
            #expect(output.components(separatedBy: "data:font/otf;base64,").count == 12)
        }
        #expect(rich.plain.contains("Western 本文"))
    }

    @Test("LaTeX を書き出した HTML の本文にも、組版時と同じ形式・文字サイズ・章の指定が残る", .timeLimit(.minutes(1)))
    func latexBodyAttributes() async throws {
        let tex = #"\documentclass[11pt]{report}\begin{document}\chapter{One}Text.\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-report" })
        let html = try await HTMLExporter.html(
            source: DocumentSource(data: Data(tex.utf8), format: .latex),
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "None")),
            title: "Report")
        let tag = try #require(html.range(of: #"<body\b[^>]*>"#, options: .regularExpression))
        let body = html[tag]
        #expect(body.contains(#"class="surimono format-latex""#))
        #expect(body.contains(#"data-latex-size="11""#))
        #expect(body.contains(#"data-latex-chapters="true""#))
        #expect(html.contains("@media screen { html { padding:"))
        #expect(!html.contains("max-width:52rem"))
    }

    @Test(
        "組み方を選んだHTMLも紙面を分け、校正の行番号は各紙面で一から振る", .timeLimit(.minutes(1)), arguments: [LaTeXComposition.twoColumn, .proof])
    func compositionPages(choice: LaTeXComposition) async throws {
        let tex = #"\documentclass{article}\begin{document}Alpha.\clearpage Bravo.\end{document}"#
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "latex-article" })
        var settings = RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: ""))
        settings.latexComposition = choice
        let html = try await HTMLExporter.html(
            source: DocumentSource(data: Data(tex.utf8), format: .latex), settings: settings, title: "Example")
        #expect(html.components(separatedBy: #"class="latex-export-page""#).count - 1 == 2)
        #expect(html.components(separatedBy: "Alpha.").count == 2)
        #expect(html.components(separatedBy: "Bravo.").count == 2)
        #expect(html.components(separatedBy: #"data-no="1""#).count - 1 == (choice == .proof ? 2 : 0))
        #expect(!html.contains("<script"))
    }

    @Test("HTMLはローカル画像と図と数式を埋め込みスクリプトとパスを残さない", .timeLimit(.minutes(1)))
    func preparedDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: folder.appendingPathComponent("local.png"))
        let markdown = "# Example\n\n![Image](local.png)\n\n$x^2$\n\n```mermaid\ngraph TD\nA --> B\n```"
        let source = DocumentSource(
            data: Data(markdown.utf8), fileURL: folder.appendingPathComponent("source.md"), format: .markdown)
        let html = try await HTMLExporter.html(
            source: source,
            settings: RenderSettings(
                layout: .a4Single,
                theme: PrintTheme(
                    id: "test", name: "Test", css: "",
                    script: "document.querySelector('h1').setAttribute('data-deco', '★');"),
                preset: HTMLCleanupPreset(id: "none", name: "None")), title: "Example")
        #expect(!html.lowercased().contains("<script"))
        #expect(!html.contains("file://"))
        #expect(!html.contains(folder.path))
        #expect(html.contains("data:image"))
        #expect(html.contains("<svg"))
        #expect(html.contains("flowchart"))
        #expect(html.contains("data-deco=\"★\""))
        #expect(html.contains("@media screen"))
        #expect(html.contains("<title>Example</title>"))
        #expect(html.contains("charset=\"utf-8\""))
    }

}
