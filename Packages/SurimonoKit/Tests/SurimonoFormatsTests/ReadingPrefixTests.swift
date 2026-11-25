import Foundation
import Testing

@testable import SurimonoFormats

struct ReadingPrefixTests {
    @Test("テキストは100万バイトを超えたときだけ先頭を組む")
    func textThreshold() {
        let text = String(repeating: "a\n", count: 500_000)
        #expect(ReadingPrefix.text(text, sourceBytes: 999_999) == nil)
        #expect(ReadingPrefix.text(text, sourceBytes: 1_000_000) == nil)
        #expect(ReadingPrefix.text(text + "z", sourceBytes: 1_000_001) == String(repeating: "a\n", count: 1_000))
    }

    @Test("バイト境界が多バイト文字やCRLFの途中なら直前の行末で切る")
    func intactLines() {
        let start = "初め\r\n"
        let padding = String(repeating: "x", count: 200_000 - start.utf8.count - 1)
        for ending in ["猫", "\r\n"] {
            let text = start + padding + ending + String(repeating: "末", count: 300_000)
            #expect(ReadingPrefix.text(text, sourceBytes: text.utf8.count) == start)
        }
    }

    @Test("終端の改行がない長い行を途中で表示しない")
    func unterminatedLine() {
        let long = String(repeating: "z", count: 1_000_001)
        #expect(ReadingPrefix.text(long, sourceBytes: long.utf8.count) == nil)
        let text = "first\rlast complete\n" + long
        #expect(ReadingPrefix.text(text, sourceBytes: text.utf8.count) == "first\rlast complete\n")
    }

    @Test("Shift_JISの全文から決めた文字コードで先頭の日本語を表示する")
    func wholeEncoding() throws {
        let text = String(repeating: "かなのログ\r\n", count: 110_000)
        let bytes = try #require(text.data(using: .shiftJIS))
        let decoded = TextDecoding.decode(bytes, preservingLineEndings: true)
        #expect(decoded.encoding == .shiftJIS)
        #expect(
            ReadingPrefix.text(decoded.text, sourceBytes: bytes.count) == String(repeating: "かなのログ\r\n", count: 1_000))
    }

    @Test("CSVは見出し込み5000レコードまで全文だけを組む", arguments: [0, 1, 2, 999, 1_000, 5_000])
    func csvThreshold(_ count: Int) {
        #expect(ReadingPrefix.csv(Array(repeating: ["x"], count: count)[...]) == nil)
    }

    @Test("CSVの先頭は見出しを一度だけ含み引用符内改行とカンマと二重引用符を保つ")
    func csvRecords() throws {
        let text =
            "label,note\r\n" + String(repeating: "a,b\r\n", count: 998)
            + "\"last,in prefix\",\"two\r\nlines with \"\"quotes\"\"\"\r\n"
            + String(repeating: "outside,tail\r\n", count: 4_000) + "end,done"
        let rows = CSVConverter.records(text, delimiter: ",", checkRow: { _ in })
        let prefix = try #require(ReadingPrefix.csv(rows[...]))
        #expect(prefix.count == 1_000)
        #expect(prefix.last == ["last,in prefix", "two\nlines with \"quotes\""])
        let html = CSVConverter.table(prefix).body
        #expect(html.hasPrefix("<table class=\"surimono-csv\"><thead><tr><th>label</th><th>note</th></tr></thead>"))
        #expect(!html.contains("outside"))
        #expect(rows.last == ["end", "done"])
    }

    @Test("最初のCSVデータ行が予算を超えたら不完全な表を出さない")
    func oversizedRecord() {
        let rows = [["header"], [String(repeating: "x", count: 200_001)]] + Array(repeating: ["a"], count: 5_000)
        #expect(ReadingPrefix.csv(rows[...]) == nil)
    }
}
