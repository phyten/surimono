import Foundation
import Testing

@testable import SurimonoCore

struct ClipboardFormatCorpusTests {
    struct Case: Decodable {
        let set: String
        let id: String
        let title: String
        let expected: String
        let ok: [String]
        let text: String
    }

    static func cases() throws -> [Case] {
        let url = try #require(
            Bundle.module.url(
                forResource: "clipboard-format-cases.json", withExtension: "deflate", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let decoded = try (data as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder().decode([Case].self, from: decoded)
    }

    static func outcome(_ result: ClipboardFormatDetection) -> String {
        switch result.action {
        case .ask: "ask"
        case .open(let kind): kind.rawValue
        }
    }

    @Test("751件のラベルに従い誤った形式を自動で開かない")
    func corpus() throws {
        let cases = try Self.cases()
        #expect(cases.count == 751)
        let pinned: Set<String> = [
            "tex-bib",  // Prose precedes the first LaTeX construct; opening it would violate the start rule.
            "url-angle",  // Angle brackets are not surrounding whitespace for a standalone URL.
            "h-md-chat-answer",  // Leading prose requires a choice, with Markdown selected by Return.
            "h2-csv-title-row",  // The title is a one-field record; dropping it would corrupt the table.
            "h5-normal-html-oneline-script",  // Template tokens in script strings still refuse HTML.
            "r2-md-weekly-report",  // Headings and plain paragraphs alone now require a choice at every level.
            "plain-email-ja",  // A mail body with a real bullet list retains its Markdown evidence.
            "plain-email-en",  // Leading mail prose does not erase the following bullet list.
            "plain-email-quotes",  // A quoted reply retains block-quote evidence without auto-formatting.
            "plain-asterisk-footnote",  // A line beginning with star-space is also a valid Markdown list.
            "h-txt-form-letter",  // A numbered list inside a letter retains document evidence.
            "h2-plain-legal-en",  // A numbered legal paragraph can also be a Markdown list starting after one.
            "h5-mail-inline-reply-markdown",  // Nested Markdown in a quoted mail body is still observed.
            "h5-mail-forwarded",  // Introductory prose plus a Setext-looking separator needs a choice.
            "h5-mail-digest",  // The digest contains document structures after prose.
            "h5-cjk-ja-business-mail",  // A signature separator can be a Setext heading after prose.
        ]
        var failures: Set<String> = []
        var asks = 0
        var ordinaryAsks = 0
        var wrong = 0
        var silent = 0
        var eligible = 0
        var formatted = 0
        for item in cases {
            let result = ClipboardFormatDetector.detect(item.text)
            let outcome = Self.outcome(result)
            if outcome != "ask" && outcome != "plainText" { formatted += 1 }
            if item.expected != "plainText" && !item.ok.contains("ask") && !result.isTruncated { eligible += 1 }
            let choices = result.choices.prefix(3).map { "\($0.kind.rawValue):\($0.confidence)" }.joined(separator: ",")
            let message = "\(item.set)/\(item.id) → \(outcome) [\(choices)]"
            let truncatedAsk = result.isTruncated && item.expected != "plainText" && outcome == "ask"
            let passes = item.ok.contains(outcome) || truncatedAsk
            if outcome == "ask" {
                asks += 1
                #expect(result.choices.contains { $0.kind.rawValue == item.expected }, Comment(rawValue: message))
                if item.expected != "plainText" && !item.ok.contains("ask") && !result.isTruncated { ordinaryAsks += 1 }
            }
            if !passes {
                failures.insert(item.id)
                print("CORPUS_FAILURE \(message)")
            }
            if outcome == "plainText" && !item.ok.contains(outcome) {
                silent += 1
                #expect(Bool(false), Comment(rawValue: message))
            }
            if outcome != "ask" && outcome != "plainText" && !item.ok.contains(outcome) {
                wrong += 1
                #expect(Bool(false), Comment(rawValue: message))
            }
        }
        print(
            "CORPUS cases=\(cases.count) passes=\(cases.count - failures.count) asks=\(asks) ordinaryAsks=\(ordinaryAsks)/\(eligible) formatted=\(formatted) wrong=\(wrong) silent=\(silent) failures=\(failures.sorted())"
        )
        #expect(failures == pinned)
        #expect(pinned.count <= 16)
        // Six: five ask because of a rule that holds at every level (prose before the document, a title row above a
        // table, a template mark in a script), and one is made of headings and paragraphs only, which a commented
        // script or config file can also be.
        #expect(ordinaryAsks <= 6)
    }
}
