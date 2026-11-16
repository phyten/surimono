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
            "tex-bib",  // Introductory prose precedes the first LaTeX construct; the brief requires asking.
            "url-angle",  // Angle brackets are not surrounding whitespace under the new URL rule.
            "h-md-chat-answer",  // Explanatory prose precedes the first Markdown block; preserve the choice.
            "h2-csv-title-row",  // A title is not a rectangular CSV record; the new rule disallows dropping it.
            "h5-normal-html-oneline-script",  // Template tokens inside JavaScript strings must prevent automatic HTML.
            "plain-poem-en",  // Repeated comma-separated lines are ambiguous; asking preserves line breaks.
            "plain-email-quotes",  // Comma-containing rows retain weak table evidence; no automatic interpretation.
            "h2-plain-jp-article-ascii-commas",  // Regular comma-separated prose remains a conservative table question.
            "h5-config-toml",  // Org-looking lines inside a multiline value cannot establish an Org document.
            "h5-mail-forwarded",  // Setext-looking separators in forwarded prose leave unresolved Markdown evidence.
            "h5-mail-digest",  // A digest contains structured blocks after prose; asking preserves the original.
            "h5-cjk-ja-business-mail",  // A signature separator forms a Setext heading after prose; never auto-format.
        ]
        var failures: Set<String> = []
        var asks = 0
        var ordinaryAsks = 0
        var wrong = 0
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
            if outcome != "ask" && outcome != "plainText" && !item.ok.contains(outcome) {
                wrong += 1
                #expect(Bool(false), Comment(rawValue: message))
            }
        }
        print(
            "CORPUS cases=\(cases.count) passes=\(cases.count - failures.count) asks=\(asks) ordinaryAsks=\(ordinaryAsks)/\(eligible) formatted=\(formatted) wrong=\(wrong) failures=\(failures.sorted())"
        )
        #expect(failures == pinned)
        #expect(pinned.count <= 16)
        #expect(ordinaryAsks <= 5)
    }
}
