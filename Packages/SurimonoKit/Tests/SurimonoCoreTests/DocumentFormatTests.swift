import SurimonoCore
import Testing
import UniformTypeIdentifiers

struct DocumentFormatTests {
    @Test(
        "主要な拡張子を対応する文書形式と判定する",
        arguments: [
            ("md", DocumentFormat.markdown), ("markdown", .markdown), ("mdown", .markdown),
            ("mkd", .markdown), ("mkdn", .markdown), ("org", .org), ("txt", .plainText),
            ("html", .html), ("htm", .html), ("pdf", .pdf), ("csv", .csv), ("zip", .zipArchive),
            ("png", .image), ("jpg", .image), ("jpeg", .image), ("gif", .image),
            ("tif", .image), ("tiff", .image), ("heic", .image), ("webp", .image),
        ])
    func detectsExtension(fileExtension: String, expected: DocumentFormat) {
        #expect(DocumentFormat(fileExtension: fileExtension) == expected)
    }

    @Test("拡張子 MD は Markdown と判定される")
    func detectsUppercaseMarkdown() {
        #expect(DocumentFormat(fileExtension: "MD") == .markdown)
    }

    @Test("拡張子の大文字小文字を区別しない", arguments: ["PDF", "PnG", "HTML", "CSV", "ORG", "TXT", "ZIP"])
    func detectsMixedCase(fileExtension: String) {
        #expect(
            DocumentFormat(fileExtension: fileExtension) == DocumentFormat(fileExtension: fileExtension.lowercased()))
    }

    @Test(
        "UTType の具体的な形式をテキストより優先する",
        arguments: [
            (UTType.surimonoMarkdown, DocumentFormat.markdown), (.surimonoOrg, .org),
            (.plainText, .plainText), (.html, .html), (.pdf, .pdf), (.image, .image),
            (.png, .image), (.jpeg, .image), (.commaSeparatedText, .csv), (.zip, .zipArchive),
        ])
    func detectsContentType(contentType: UTType, expected: DocumentFormat) {
        #expect(DocumentFormat(contentType: contentType) == expected)
    }

    @Test("未知のテキスト準拠 UTType はプレーンテキストになる")
    func fallsBackToText() throws {
        let type = try #require(UTType(filenameExtension: "surimono-test-text", conformingTo: .text))
        #expect(DocumentFormat(contentType: type) == .plainText)
    }

    @Test("未対応の拡張子と UTType は nil になる")
    func rejectsUnsupportedTypes() {
        #expect(DocumentFormat(fileExtension: "") == nil)
        #expect(DocumentFormat(fileExtension: "surimono-unknown") == nil)
        #expect(DocumentFormat(contentType: .data) == nil)
        #expect(DocumentFormat(contentType: .folder) == nil)
    }

    @Test("各形式が英語の表示名を持つ")
    func providesDisplayNames() {
        #expect(
            DocumentFormat.allCases.map(\.displayName) == [
                "Markdown", "Org", "Plain Text", "HTML", "PDF", "Image", "CSV", "ZIP",
            ])
    }

    @Test("ZIPはHTML組版や印刷テーマの対象にしない")
    func zipRenderingFlags() {
        #expect(!DocumentFormat.zipArchive.isWebRendered)
        #expect(!DocumentFormat.zipArchive.usesPrintTheme)
        #expect(!DocumentFormat.zipArchive.usesHTMLPreset)
    }
}
