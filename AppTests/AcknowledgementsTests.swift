import Foundation
import Testing

@testable import Surimono

struct AcknowledgementsTests {
    /// The licenses of what the app ships ask for their text, and for Apache-2.0 the NOTICE file too, to travel with
    /// every copy. A dependency added or renamed without its text would otherwise go out unnoticed.
    @Test(
        "同梱している依存のライセンス文と表示が、アプリの中に入っている",
        arguments: [
            "swift-markdown-LICENSE.txt", "swift-markdown-NOTICE.txt", "swift-cmark-COPYING.txt",
            "asciidoctor-LICENSE.txt", "SwaTex-LICENSE.txt", "SwaTex-THIRD-PARTY-NOTICES.md", "KaTeX-Fonts-OFL.txt",
            "viz-LICENSE.txt", "viz-THIRD-PARTY-NOTICES.txt", "plantuml-LICENSE.txt",
            "mermaid-LICENSE.txt", "gemoji-LICENSE.txt", "Sparkle-LICENSE.txt",
        ])
    func bundled(name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: nil))
        #expect(try Data(contentsOf: url).isEmpty == false)
    }
}
