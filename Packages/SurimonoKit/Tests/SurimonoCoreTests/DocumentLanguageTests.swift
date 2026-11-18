import Testing

@testable import SurimonoCore

struct DocumentLanguageTests {
}

extension DocumentLanguageTests {
    @Test("プレーンテキストのpreはコードとして除外しない")
    func plainText() {
        let fragment = PlainTextConverter.convert(
            "This imaginary library opens every morning. Visitors read their books and write stories.")
        #expect(HTMLDocumentBuilder.language(for: fragment).code == "en")
    }
}
