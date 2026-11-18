import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SurimonoCore

struct DocxTests {
    private var sample: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../../Samples/sample.docx"
        ).standardizedFileURL
    }

    @Test("Wordの文書を画像の束へ渡さない")
    func routing() throws {
        #expect(DocumentFormat(fileExtension: "DOCX") == .docx)
        let type = UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
        #expect(DocumentFormat(contentType: type) == .docx)
        #expect(OpenRequest.binderFormat(sample) == .docx)
        #expect(!OpenRequest.isArchive(sample))
        let image = sample.deletingLastPathComponent().appendingPathComponent("z.png")
        #expect(OpenRequest(urls: [image, sample]) == .binder([sample, image], excluded: []))
        #expect(ClipboardTextKind(.docx) == nil)
    }
}
