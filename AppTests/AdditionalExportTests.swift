import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct AdditionalExportTests {
    @Test("PNGの出力先は新規の連番フォルダで既存ファイルを上書きしない")
    func folders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ExportFiles.newFolder(in: root, name: "Sample")
        let second = try ExportFiles.newFolder(in: root, name: "Sample")
        #expect(first.lastPathComponent == "Sample")
        #expect(second.lastPathComponent == "Sample 2")
        #expect(ExportFiles.pageName("Sample", index: 0, count: 120) == "Sample-001.png")
        #expect(ExportFiles.pageName("Sample", index: 0, count: 2) == "Sample-01.png")
    }

    @Test("PNGは読むページを新しいフォルダへ書き出し元ファイルを保護する", .timeLimit(.minutes(1)))
    func readingImages() async throws {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let original = TestFixtures.pdf("Example", pages: 2)
        let source = root.appendingPathComponent("Example.pdf")
        try original.write(to: source)
        let model = DocumentViewModel(
            data: original, fileURL: source, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
        defer { model.stop() }
        model.render()
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await model.performReadingExport(.png, destination: root, dpi: 72))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Example/Example-01.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Example/Example-02.png").path))
        #expect(!(await model.performReadingExport(.png, destination: source, dpi: 72)))
        #expect(try Data(contentsOf: source) == original)
        #expect(!model.isExporting)
    }

    @Test("解像度はアプリ全体で記憶し未知の値は144に戻す")
    func resolution() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.exportImageDPI == 144)
        preferences.exportImageDPI = 300
        #expect(AppPreferences(defaults: suite.defaults).exportImageDPI == 300)
        preferences.exportImageDPI = 900
        #expect(preferences.exportImageDPI == 144)
    }

    @Test("リッチテキストは専用ペーストボードへ四形式を渡す")
    func clipboard() throws {
        let board = NSPasteboard(name: .init("SurimonoTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        try ExportClipboard.copy(html: "<html><body><b>Hello</b></body></html>", to: board)
        #expect(board.data(forType: .html) != nil)
        #expect(board.data(forType: .rtf) != nil)
        #expect(board.data(forType: .rtfd) != nil)
        #expect(board.string(forType: .string) == "Hello")
    }

    @Test("数式と図のコピーは文字の崩れがなくRTFDに画像を含む", .timeLimit(.minutes(1)))
    func richMathClipboard() async throws {
        let board = NSPasteboard(name: .init("SurimonoTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let content = try await HTMLExporter.content(
            source: DocumentSource(
                data: Data("$a^2 + b^2$\n\n```mermaid\ngraph TD\nA --> B\n```".utf8),
                format: .markdown),
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
                preset: HTMLCleanupPreset(id: "none", name: "None")), title: "Test", richText: true)
        try ExportClipboard.copy(html: content.html, plainText: content.plainText, to: board)
        let html = try #require(board.string(forType: .html))
        #expect(html.contains("data:image/png"))
        #expect(!html.contains("<svg"))
        let rtf = try NSAttributedString(
            data: #require(board.data(forType: .rtf)),
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        for text in [try #require(board.string(forType: .string)), rtf.string] {
            #expect(!text.contains("font-family"))
            #expect(!text.contains("#surimono-mermaid"))
            #expect(text.range(of: #"(?m)^\s*a\s*\n\s*2\s*\n"#, options: .regularExpression) == nil)
        }
        let rtfd = try NSAttributedString(
            data: #require(board.data(forType: .rtfd)),
            options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        var attachments = 0
        rtfd.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rtfd.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        #expect(attachments >= 1)
    }

}
