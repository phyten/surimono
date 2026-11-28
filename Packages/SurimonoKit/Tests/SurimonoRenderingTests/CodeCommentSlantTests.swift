import CoreGraphics
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct CodeCommentSlantTests {
    /// The text matrices of a page: a machine-slanted face is drawn with a shear in the matrix.
    private static func shears(of page: CGPDFPage) -> [CGFloat] {
        final class Box { var shears: [CGFloat] = [] }
        let box = Box()
        guard let table = CGPDFOperatorTableCreate() else { return [] }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in (0..<6).reversed() { _ = CGPDFScannerPopNumber(scanner, &values[index]) }
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().shears.append(values[2])
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(box).toOpaque())
        CGPDFScannerScan(scanner)
        return box.shears
    }

    @Test(
        "コードの和文のコメントは機械的に斜めにしない", .timeLimit(.minutes(1)),
        arguments: [
            ("```python\n# 和文のコメント\nx = 1\n```\n", DocumentFormat.markdown), ("# 和文のコメント\nx = 1\n", .plainText),
        ])
    func japaneseComment(text: String, format: DocumentFormat) async throws {
        let theme = try #require(PrintThemeLibrary.load().first { $0.id == "standard" })
        let source =
            format == .plainText
            ? DocumentSource(data: Data(text.utf8), format: format).named("queue.py")
            : DocumentSource(data: Data(text.utf8), format: format)
        let result = try await DocumentRenderer().prepare(
            source,
            settings: RenderSettings(layout: .a4Single, theme: theme, preset: .init(id: "none", name: "")))
        let page = try #require(result.logicalDocument.page(at: 0)?.pageRef)
        #expect(Self.shears(of: page).allSatisfy { abs($0) < 0.01 })
    }
}
