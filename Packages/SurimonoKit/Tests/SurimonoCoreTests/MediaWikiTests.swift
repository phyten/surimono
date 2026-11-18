import Foundation
import Testing

@testable import SurimonoCore

struct MediaWikiTests {
    @Test("角括弧のリンクを含むMarkdownをMarkdownとして開く")
    func obsidian() {
        let source = "# Title\n\nText [[Other]].\n\n## Section\n\n- one\n- two\n- three\n"
        #expect(ClipboardFormatDetector.detect(source).action == .open(.markdown))
    }

    @Test("同じ種類の手がかりを二度数えない")
    func repeatedSignal() {
        for text in ["[[A]] and [[B]]", "[[Paper]] and `{{example}}`", "[[Paper]] <!-- {{Hidden}} -->"] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.mediawiki))
        }
    }

    @Test("独立した記号を二つ必要とする")
    func clipboard() {
        #expect(ClipboardFormatDetector.detect("== Notes ==\n[[Paper]]").action == .open(.mediawiki))
        for source in ["# Notes\n[[Paper]]", "* Notes\n[[Paper]]", "= Notes\n== Paper", "plain text"] {
            #expect(ClipboardFormatDetector.detect(source).action != .open(.mediawiki))
        }
    }
}
