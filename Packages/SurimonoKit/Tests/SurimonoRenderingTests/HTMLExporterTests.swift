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

}
