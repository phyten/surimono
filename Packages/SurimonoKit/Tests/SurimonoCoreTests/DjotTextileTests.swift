import CryptoKit
import Foundation
import Testing

@testable import SurimonoCore

struct DjotTextileTests {
    @Test("コードの配色と行番号を適用できる囲みを作る", arguments: [DocumentFormat.djot, .textile])
    func code(format: DocumentFormat) throws {
        let doc = try convert(format, "```swift\nlet a = 1\n```", "bc(swift). let a = 1")
        #expect(CodeBlockMarkup.apply(.init(block: .init(lineNumbers: .all)), to: doc.body).contains("code-block"))
        #expect(doc.body.contains("<pre><code class=\"language-swift hl\">"))
    }

    @Test("二つの固有の印でTextileを判定する")
    func clipboard() {
        #expect(ClipboardFormatDetector.detect("h1. Title\n\nbq. Paper").action == .open(.textile))
        #expect(ClipboardFormatDetector.detect("h1. Title\n\nh2. Section").action == .open(.textile))
        for text in [
            #"{"count":2,"size":4}"#, "Ordinary prose", "h1. Title", "# Title\n\n- paper",
            "```textile\nh1. Title\nbq. Paper\n```",
        ] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.textile))
        }
    }

    private func convert(_ format: DocumentFormat, _ djot: String, _ textile: String) throws -> HTMLFragment {
        try format == .djot ? DjotConverter.convert(djot) : TextileConverter.convert(textile)
    }
}
