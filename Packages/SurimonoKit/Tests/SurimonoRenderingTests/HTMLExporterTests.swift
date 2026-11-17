import AppKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct HTMLExporterTests {
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

    @Test("リッチテキスト用の数式は埋め込み書体で空白でない2倍PNGになりSVGとCSSを本文に残さない", .timeLimit(.minutes(1)))
    func bitmapMath() async throws {
        let source = DocumentSource(
            data: Data("# Test\n\n$a^2 + b^2$\n\n$$\n\\frac{1}{2}\n$$\n\n```mermaid\ngraph TD\nA --> B\n```".utf8),
            format: .markdown)
        let result = try await HTMLExporter.content(
            source: source,
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { color: black; }"),
                preset: HTMLCleanupPreset(id: "none", name: "None")), title: "Test", richText: true)
        #expect(!result.html.contains("<svg"))
        let plain = try #require(result.plainText)
        #expect(plain.contains("a^2 + b^2"))
        #expect(plain.contains("\\frac{1}{2}"))
        #expect(!plain.contains("font-family"))
        #expect(!plain.contains("#surimono-mermaid"))
        let expression = try NSRegularExpression(pattern: #"<img[^>]*src="data:image/png;base64,([^"]+)"[^>]*>"#)
        let html = result.html as NSString
        let matches = expression.matches(in: result.html, range: NSRange(location: 0, length: html.length))
        #expect(matches.count == 3)
        for match in matches {
            let bytes = try #require(Data(base64Encoded: html.substring(with: match.range(at: 1))))
            let bitmap = try #require(NSBitmapImageRep(data: bytes))
            let tag = html.substring(with: match.range) as NSString
            let sizeExpression = try NSRegularExpression(pattern: #"width:\s*([0-9.]+)px;\s*height:\s*([0-9.]+)px"#)
            let size = try #require(
                sizeExpression.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)))
            let width = try #require(Double(tag.substring(with: size.range(at: 1))))
            let height = try #require(Double(tag.substring(with: size.range(at: 2))))
            #expect(abs(Double(bitmap.pixelsWide) - width * 2) <= 1)
            #expect(abs(Double(bitmap.pixelsHigh) - height * 2) <= 1)
            var ink = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0.5,
                        min(color.redComponent, color.greenComponent, color.blueComponent) < 0.5
                    {
                        ink += 1
                    }
                }
            }
            #expect(ink > 20)
        }
    }

}
