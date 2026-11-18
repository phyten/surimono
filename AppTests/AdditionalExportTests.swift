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

    @Test("専用ペーストボードの4形式に表・入れ子リスト・数式・図・ローカル画像をコピーする", .timeLimit(.minutes(1)))
    func copyRichText() async throws {
        let generalCount = NSPasteboard.general.changeCount
        let board = NSPasteboard(name: .init("SurimonoTests.richText.\(UUID())"))
        defer {
            board.releaseGlobally()
            #expect(NSPasteboard.general.changeCount == generalCount)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = TestDefaultsSuite()
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("Rich.md")
        let markdown = """
            # Heading

            | First | Second |
            | --- | --- |
            | A | B |
            | C | D |

            - Outer
              - Inner

            Inline $x^2$.

            $$
            y+1
            $$

            ```mermaid
            graph TD
            A --> B
            ```

            ![Sample photo](figure.png)
            """
        let bytes = Data(markdown.utf8)
        try bytes.write(to: source)
        try TestFixtures.png(red: 0.7).write(to: root.appendingPathComponent("figure.png"))
        let model = DocumentViewModel(
            data: bytes, fileURL: source, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
        defer { model.stop() }
        model.render()
        while model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await model.performReadingExport(.richText, pasteboard: board))
        #expect(Set(board.types ?? []).isSuperset(of: [.rtfd, .rtf, .html, .string]))
        let flat = try #require(board.data(forType: .rtfd))
        let files = try #require(FileWrapper(serializedRepresentation: flat)?.fileWrappers)
        #expect(Set(files.keys) == ["TXT.rtf", "image-001.png", "image-002.png", "image-003.png", "image-004.png"])
        let html = try #require(board.string(forType: .html))
        let dom = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let images = try dom.nodes(forXPath: "//img").compactMap { $0 as? XMLElement }
        try #require(images.count == 4)
        let rich = try #require(NSAttributedString(rtfd: flat, documentAttributes: nil))
        var attachments = [NSTextAttachment]()
        var cells = Set<ObjectIdentifier>()
        var depth = 0
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, _, _ in
            if let a = attributes[.attachment] as? NSTextAttachment { attachments.append(a) }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                depth = max(depth, style.textLists.count)
                for case let cell as NSTextTableBlock in style.textBlocks { cells.insert(ObjectIdentifier(cell)) }
            }
        }
        #expect(cells.count == 6)
        #expect(depth >= 2)
        try #require(attachments.count == 4)
        for (index, pair) in zip(attachments, images).enumerated() {
            let (attachment, element) = pair
            let width = try #require(element.attribute(forName: "width")?.stringValue.flatMap(Double.init))
            let height = try #require(element.attribute(forName: "height")?.stringValue.flatMap(Double.init))
            // Some RTFD readers leave bounds automatic and use the attachment cell's intrinsic size.
            let size = attachment.bounds.isEmpty ? attachment.attachmentCell?.cellSize() : attachment.bounds.size
            let displayed = try #require(size)
            #expect(abs(displayed.width - width) <= 1)
            #expect(abs(displayed.height - height) <= 1)
            if index < 3 {
                let data = try #require(attachment.fileWrapper?.regularFileContents)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                #expect(abs(Double(bitmap.pixelsWide) - width * 2) <= 2)
                let first = bitmap.colorAt(x: 0, y: 0)
                #expect(
                    (0..<bitmap.pixelsHigh).contains { y in
                        (0..<bitmap.pixelsWide).contains { x in bitmap.colorAt(x: x, y: y) != first }
                    })
            }
        }
        let plain = try #require(board.string(forType: .string))
        for alt in ["x^2", "y+1", "Sample photo"] { #expect(plain.contains(alt)) }
        for noise in ["{font-family", "<svg", "\u{fffc}"] { #expect(!plain.contains(noise)) }
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

}
