import Foundation
import Testing

@testable import SurimonoCore

struct AsciiDocTests {
    @Test("ソースブロックに配色・説明・注番号を残す")
    func code() throws {
        let html = try AsciiDocConverter.convert(".Listing\n[source,swift]\n----\nlet a = 1 // <1>\n----\n<1> Value")
            .body
        for text in ["<figcaption>Listing", "<pre><code class=\"language-swift hl\"", "Value", "(1)"] {
            #expect(html.contains(text))
        }
        #expect(CodeBlockMarkup.apply(.init(block: .init(lineNumbers: .all)), to: html).contains("code-block"))
    }

    @Test("AsciiDocの拡張子と複数の構文の印で判定する")
    func detection() {
        for ext in ["adoc", "ASCIIDOC"] { #expect(DocumentFormat(fileExtension: ext) == .asciidoc) }
        #expect(ClipboardFormatDetector.detect("= Title\n\n== Section").action == .open(.asciidoc))
        for text in ["= Title", "# Markdown\n\n----", "ordinary\nNOTE: prose"] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.asciidoc))
        }
    }
}
