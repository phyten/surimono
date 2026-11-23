import PDFKit
import Testing

@testable import SurimonoRendering

@MainActor
struct ReadingPDFSnapshotTests {
    @Test("宛先のページが解放されたリンクやしおりは、行先なしとして保存しない", arguments: [false, true])
    func lostPage(bookmark: Bool) async throws {
        let document = try RenderingFixtures.pdf()
        let destination = autoreleasepool { PDFDestination(page: PDFPage(), at: .zero) }
        try #require(destination.page == nil)
        let action = PDFActionGoTo(destination: destination)
        if bookmark {
            let root = PDFOutline()
            let child = PDFOutline()
            child.label = "Lost"
            root.insertChild(child, at: 0)
            child.action = action
            document.outlineRoot = root
        } else {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 1, y: 2, width: 3, height: 4), forType: .link, withProperties: nil)
            annotation.action = action
            try #require(document.page(at: 0)).addAnnotation(annotation)
        }
        await #expect(throws: ReadingPDFExporter.ExportError.self) {
            _ = try await ReadingPDFExporter.data(from: document, entries: [], title: "Test", preservesOutline: true)
        }
    }

    @Test("多数のページを調べている途中で取り消すと、残りを走査しない")
    func cancelledSnapshot() async throws {
        let document = CancellingDocument()
        for index in 0..<256 { document.insert(PDFPage(), at: index) }
        document.reads = 0
        let task = Task { @MainActor in _ = try await ReadingPDFNavigation(document) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect((8..<256).contains(document.reads ?? 0))
    }
}

// Cancel from inside the scan so a check at entry or after the last page cannot pass the test.
private final class CancellingDocument: PDFDocument {
    var reads: Int?
    override func page(at index: Int) -> PDFPage? {
        if let reads {
            self.reads = reads + 1
            if reads + 1 == 8 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        return super.page(at: index)
    }
}
