import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import SurimonoFormats

struct RSTFormatTests {
    @Test("エスケープで奇数位置だけを通っても区切りの索引作成と本文変換の両方が期限を見る")
    func escapedInlineDeadline() {
        let start = ContinuousClock.now
        let deadline = start + .seconds(1)
        let checks = Mutex(0)
        let request = PreviewConversion(deadline: deadline) {
            checks.withLock {
                $0 += 1
                // Each scan crosses four intervals. Skipping either scan's checks would miss this deadline.
                return $0 >= 6 ? deadline : start
            }
        }
        let document = RSTDocument(directory: nil, permitsFile: { _ in false })
        let html = PreviewConversion.$current.withValue(request) {
            document.inline("a" + String(repeating: #"\x"#, count: 512))
        }
        #expect(html.isEmpty)
        #expect(checks.withLock { $0 } >= 6)
    }

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
