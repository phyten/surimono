import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SurimonoFormats

struct RSTFormatTests {
    @Test("両方の拡張子と読み取り用の型が同じ形式を開く")
    func fileTypes() {
        for suffix in ["rst", "Rest", "RST"] {
            #expect(DocumentFormat(fileExtension: suffix) == .rst)
        }
        #expect(DocumentFormat(contentType: .surimonoRST) == .rst)
        #expect(DocumentFormat.rst.usesPrintTheme)
        #expect(DocumentFormat.rst.supportsChangeMarks)
    }

    @Test("二メガバイトの原稿を末尾まで読み取る", .timeLimit(.minutes(1)))
    func largeDocument() {
        let row = String(repeating: "Paper fibres ", count: 12) + "dry on the rack.\n\n"
        let text = String(repeating: row, count: 2_000_000 / row.utf8.count + 1) + "Last sheet."
        let start = ContinuousClock.now
        let result = RSTConverter.convert(text)
        print("RST_2MB bytes=\(text.utf8.count) elapsed=\(start.duration(to: .now))")
        #expect(result.body.contains("<p>Last sheet.</p>"))
        #expect(result.readingIssues.isEmpty)
    }
}
