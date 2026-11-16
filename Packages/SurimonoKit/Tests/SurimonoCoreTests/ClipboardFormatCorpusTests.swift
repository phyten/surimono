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
        // The remaining clear documents need a choice because of leading prose, a title row or a template mark.
        #expect(eligible == 181)
        #expect(ordinaryAsks <= 5)
    }
}

extension ClipboardFormatCorpusTests {
    @Test("両fixtureのプレーンテキスト567件への確認は163件以内に収める")
    func plainTextQuestions() throws {
        var count = 0
        var asks = 0
        for item in try Self.cases() where item.expected == "plainText" {
            count += 1
            if case .ask = ClipboardFormatDetector.detect(item.text).action { asks += 1 }
        }
        for item in try ClipboardFormatReviewTests.cases() where item.expected == "plainText" {
            count += 1
            let result = ClipboardFormatDetector.detect(
                item.text,
                hints: .init(hasMatchingURL: item.url ?? false, hasTabularData: item.tabular ?? false),
                settings: .init(mode: item.mode ?? .askWhenUnsure, carefulness: item.carefulness ?? .standard))
            if case .ask = result.action { asks += 1 }
        }
        print("PLAIN_QUESTIONS cases=\(count) asks=\(asks)")
        #expect(count == 567)
        #expect(asks <= 163)
    }
}

extension ClipboardFormatCorpusTests {
    @Test("前回質問へ退行した41件のうち34件以上は確認せずプレーンテキストへ戻る")
    func plainTextRegressions() throws {
        let ids: Set<String> = [
            "tex-inline-text",
            "plain-email-ja",
            "plain-email-en",
            "plain-recipe",
            "plain-asterisk-footnote",
            "h-txt-commit-message",
            "h-txt-form-letter",
            "h-txt-shopping-stars",
            "h2-plain-legal-en",
            "r1-ignore-japanese",
            "r1-crontab-weekday",
            "r1-yaml-quoted-keys",
            "o-10",
            "o-13",
            "h3-ja-asterisk-note",
            "h3-ja-recipe",
            "r2-table-scattered",
            "h4-code-go-html",
            "h4-code-js-template-html",
            "h4-code-c-comment-md",
            "h4-code-java-javadoc-html",
            "h4-code-angular",
            "h4-code-sql-md",
            "h4-mention-ticket-error-page",
            "r3-table-extra-cell",
            "r3-context-diff",
            "h5-code-env-multiline-markdown",
            "h5-code-python-readme-template",
            "h5-code-scala-csv",
            "h5-code-go-raw-csv",
            "h5-code-sql-csv-copy",
            "h5-mail-inline-reply-markdown",
            "h5-table-thousand-separators",
            "tex-inline-in-prose",
            "csv-semicolon-eu",
            "pt-asterisk-footnote",
            "pt-dash-list-casual",
            "pt-numbered-casual",
            "pt-commit-msg-md",
            "pt-asterisk-bullets-email",
            "nbsp-heading",
        ]
        let asks: Set<String> = [
            "r2-table-scattered", "h4-mention-ticket-error-page", "r3-table-extra-cell",
            "h5-mail-inline-reply-markdown", "h5-table-thousand-separators", "csv-semicolon-eu", "nbsp-heading",
        ]
        var observed: Set<String> = []
        var restored = 0
        func check(_ id: String, _ result: ClipboardFormatDetection) {
            observed.insert(id)
            if result.action == .open(.plainText) { restored += 1 }
            if asks.contains(id) {
                #expect(Self.outcome(result) == "ask", Comment(rawValue: id))
            } else {
                #expect(result.action == .open(.plainText), Comment(rawValue: id))
            }
        }
        for item in try Self.cases() where ids.contains(item.id) {
            check(item.id, ClipboardFormatDetector.detect(item.text))
        }
        for item in try ClipboardFormatReviewTests.cases() where ids.contains(item.id) {
            check(
                item.id,
                ClipboardFormatDetector.detect(
                    item.text,
                    hints: .init(hasMatchingURL: item.url ?? false, hasTabularData: item.tabular ?? false),
                    settings: .init(mode: item.mode ?? .askWhenUnsure, carefulness: item.carefulness ?? .standard)))
        }
        #expect(ids.count == 41)
        #expect(observed == ids)
        #expect(restored >= 34)
    }
}
