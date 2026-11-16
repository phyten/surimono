import Foundation
import Testing

@testable import SurimonoCore

struct ClipboardFormatReviewTests {
    struct Case: Decodable {
        let set: String
        let id: String
        let ok: [String]
        let text: String
        let mode: ClipboardFormatSettings.Mode?
        let carefulness: ClipboardFormatSettings.Carefulness?
        let tabular: Bool?
        let url: Bool?
    }

    static func cases() throws -> [Case] {
        let url = try #require(
            Bundle.module.url(
                forResource: "clipboard-format-cases-review.json", withExtension: "deflate", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let decoded = try (data as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder().decode([Case].self, from: decoded)
    }

    @Test("独立レビュー284件で誤整形と黙示的プレーン化を防ぎ残る質問を固定する")
    func review() throws {
        let cases = try Self.cases()
        #expect(cases.count == 284)
        let pinned: [String: String] = [
            "b-hash-only": "An empty ATX heading is observed but cannot justify Markdown.",
            "html-prose-about-tags": "Inline tag examples retain weak HTML evidence and ask.",
            "pt-latex-cmd-in-prose": "Prose before LaTeX commands requires a choice.",
        ]
        var failures: Set<String> = []
        var asks = 0
        var wrong = 0
        var silent = 0
        for item in cases {
            let result = ClipboardFormatDetector.detect(
                item.text,
                hints: .init(hasMatchingURL: item.url ?? false, hasTabularData: item.tabular ?? false),
                settings: .init(mode: item.mode ?? .askWhenUnsure, carefulness: item.carefulness ?? .standard))
            let outcome = ClipboardFormatCorpusTests.outcome(result)
            let message = "\(item.set)/\(item.id): \(outcome), \(result.reason)"
            if outcome == "ask" { asks += 1 }
            if !item.ok.contains(outcome) {
                failures.insert(item.id)
                print("REVIEW_FAILURE \(message)")
                if outcome == "plainText" { silent += 1 }
                if outcome != "ask" && outcome != "plainText" { wrong += 1 }
                #expect(outcome == "ask", Comment(rawValue: message))
            }
        }
        print(
            "REVIEW cases=\(cases.count) passes=\(cases.count - failures.count) asks=\(asks) wrong=\(wrong) silent=\(silent) failures=\(failures.sorted())"
        )
        #expect(failures == Set(pinned.keys))
        #expect(pinned.count <= 14)
    }
}
