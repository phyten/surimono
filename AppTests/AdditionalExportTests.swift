import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

@MainActor
struct AdditionalExportTests {
    @Test("原本のない文書の共有先が二度求めても同じ読むためのPDFを渡し、文書を閉じると一時ファイルを片付ける")
    func shareReadingFile() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DocumentViewModel(
            data: TestFixtures.pdf("Example", pages: 2), fileURL: nil, format: .pdf,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
        defer { model.stop() }
        model.render()
        for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        let share = try #require(model.makeReadingShare())
        model.readingShare = share
        var results: [Result<URL, Error>] = []
        share.load(Progress(totalUnitCount: 1)) { results.append($0) }
        share.load(Progress(totalUnitCount: 1)) { results.append($0) }
        let deadline = ContinuousClock.now + .seconds(5)
        while results.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(results.count == 2)
        let first = try results[0].get()
        #expect(try results[1].get() == first)
        #expect(PDFDocument(url: first)?.pageCount == 2)
        model.stop()
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test("共有用PDFの要求を片方だけ取り消しても、もう片方に同じ生成処理からPDFが届く")
    func cancelOneShareRequest() async throws {
        let bytes = TestFixtures.pdf("Remaining request")
        var resume: CheckedContinuation<Void, Never>?
        var starts = 0
        let share = ReadingPDFShare(name: "Remaining.pdf", protectedURLs: []) {
            starts += 1
            await withCheckedContinuation { resume = $0 }
            try Task.checkCancellation()
            return bytes
        }
        defer {
            share.cancel()
            resume?.resume()
        }
        let first = Progress(totalUnitCount: 1)
        let second = Progress(totalUnitCount: 1)
        var cancelled: [Result<URL, Error>] = []
        var remaining: [Result<URL, Error>] = []
        share.load(first) { cancelled.append($0) }
        share.load(second) { remaining.append($0) }
        try await ShortcutMenuBaselineTests.waitForMenu { resume != nil }
        first.cancel()
        try await ShortcutMenuBaselineTests.waitForMenu { !cancelled.isEmpty }
        #expect(remaining.isEmpty)
        resume?.resume()
        resume = nil
        try await ShortcutMenuBaselineTests.waitForMenu { !remaining.isEmpty }
        #expect(starts == 1)
        try #require(cancelled.count == 1 && remaining.count == 1)
        #expect(throws: CancellationError.self) { try cancelled[0].get() }
        let file = try remaining[0].get()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(second.completedUnitCount == 1)
        share.cancel()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("遅れて共有用PDFを求められても、閉じた文書のモデルを保持せずデータを渡さない")
    func lateShareRequestAfterClose() async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        weak var released: DocumentViewModel?
        let share: ReadingPDFShare
        do {
            let model = DocumentViewModel(
                data: TestFixtures.pdf("Late request"), fileURL: nil, format: .pdf,
                preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
            defer { model.stop() }
            model.render()
            try await ShortcutMenuBaselineTests.waitForMenu { model.canExportReadingPDF }
            share = try #require(model.makeReadingShare())
            released = model
        }
        try await ShortcutMenuBaselineTests.waitForMenu { released == nil }
        // Keep the actual producer alive as a delayed service would, without opening a picker.
        let result = await withCheckedContinuation { continuation in
            share.load(Progress(totalUnitCount: 1)) { continuation.resume(returning: $0) }
        }
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("共有の取り消しと文書終了は生成中の作業を取り消し、それぞれの要求へ一度だけ答える", arguments: [true, false])
    func cancelSharing(stoppingDocument: Bool) async throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .plainText,
            preferences: AppPreferences(defaults: suite.defaults),
            library: UserLibrary(root: root))
        var started = false
        var cancelled = false
        let share = ReadingPDFShare(name: "Cancel.pdf", protectedURLs: []) {
            started = true
            defer { cancelled = Task.isCancelled }
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        model.readingShare = share
        let progress = Progress(totalUnitCount: 1)
        var results: [Result<URL, Error>] = []
        share.load(progress) { results.append($0) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(started)
        if stoppingDocument { model.stop() } else { progress.cancel() }
        while !cancelled && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancelled)
        model.stop()
        try #require(results.count == 1)
        #expect(throws: CancellationError.self) { try results[0].get() }
    }

    @Test("数式のコピーは展開前の原文だけをテキストとして渡す")
    func formulaSource() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root))
        defer { model.stop() }
        let board = NSPasteboard(name: .init("SurimonoTests.formula.\(UUID())"))
        defer { board.releaseGlobally() }
        let source = #"\begin{align}\葉 &= 2\end{align}"#
        let formula = RenderedDiagram(number: 1, pageIndex: 0, rect: .zero, svg: "<svg/>", formulaSource: source)
        model.exportDiagram(formula, action: .copySource, pasteboard: board)
        #expect(board.pasteboardItems?.map(\.types) == [[.string]])
        #expect(board.string(forType: .string) == source)
    }

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
